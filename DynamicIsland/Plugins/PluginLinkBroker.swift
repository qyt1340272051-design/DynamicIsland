import AppKit
import Foundation

nonisolated enum PluginLinkError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments, policyDenied, rateLimited, openFailed, inactiveExecution, permissionRevoked

    var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .policyDenied: "linkPolicyDenied"
        case .rateLimited: "rateLimited"
        case .openFailed: "linkOpenFailed"
        case .inactiveExecution: "inactiveExecution"
        case .permissionRevoked: "permissionRevoked"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid link arguments."
        case .policyDenied: "The Host link policy rejected this address."
        case .rateLimited: "Please wait before opening another link."
        case .openFailed: "The system could not open the link."
        case .inactiveExecution: "This plugin execution is inactive."
        case .permissionRevoked: "The link authorization is no longer valid."
        }
    }
}

/// Retain the original string until it has passed validation: URL parsing may
/// otherwise silently encode whitespace or repair malformed percent escapes.
nonisolated struct PluginLinkRequest: Sendable {
    let url: URL

    init(source: String) throws {
        guard !source.isEmpty, source.utf8.count <= 2_048,
              !Self.containsForbiddenCharacters(source),
              let decoded = source.removingPercentEncoding,
              !Self.containsForbiddenCharacters(decoded),
              let components = URLComponents(string: source), let url = components.url,
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.percentEncodedHost, Self.isDNSHost(host)
        else { throw PluginLinkError.invalidArguments }
        self.url = url
    }

    fileprivate static func normalizedHost(_ source: String) -> String? {
        guard isDNSHost(source) else { return nil }
        return source.lowercased()
    }

    private static func containsForbiddenCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            $0 == "\\" || CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func isDNSHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.hasPrefix("."), !host.hasSuffix("."), host.contains("."),
              host.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 46
              }), host.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) })
        else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
    }
}

/// Opens only a bounded HTTPS address through the system. The synchronous
/// opener is a leaf side effect: it must not change grants or reenter gates.
@MainActor
public final class PluginLinkBroker {
    public typealias Opener = @MainActor (URL) -> Bool
    private let allowedHosts: Set<String>
    private let now: @MainActor () -> ContinuousClock.Instant
    private let opener: Opener
    private var lastAttempt: ContinuousClock.Instant?

    public init(allowedHosts: Set<String> = ["github.com"],
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
                opener: Opener? = nil) {
        self.allowedHosts = Set(allowedHosts.compactMap { PluginLinkRequest.normalizedHost($0) })
        self.now = now
        self.opener = opener ?? { NSWorkspace.shared.open($0) }
    }

    func open(request: PluginLinkRequest, pluginID: String, authorization: PluginPermissionLease,
              admission: PluginResourceAdmission, validate: @MainActor () throws -> Void) throws {
        guard let host = request.url.host?.lowercased(), allowedHosts.contains(host) else {
            throw PluginLinkError.policyDenied
        }
        let instant = now()
        if let lastAttempt, instant < lastAttempt.advanced(by: .seconds(1)) {
            throw PluginLinkError.rateLimited
        }
        // The injected clock and the ActionRouter authorizer may reenter Host
        // state. Run the final instance/registration check after those calls,
        // before acquiring the non-reentrant resource and permission gates.
        try validate()
        if let lastAttempt, instant < lastAttempt.advanced(by: .seconds(1)) {
            throw PluginLinkError.rateLimited
        }
        try admission.perform {
            try authorization.perform(pluginID: pluginID, permission: .openLinks) {
                lastAttempt = instant
                guard opener(request.url) else { throw PluginLinkError.openFailed }
            }
        }
    }
}
