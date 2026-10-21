import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginLinkBrokerTests: XCTestCase {
    private let alpha = "com.example.links.alpha"

    func testAllowedHTTPSLinkPreservesPathQueryFragmentAndAcceptsHostCaseAndExplicit443() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let broker = PluginLinkBroker(allowedHosts: ["GITHUB.COM"], opener: opened.open)
        let request = try PluginLinkRequest(source:
            "HTTPS://GITHUB.COM:443/owner/repo/pull/7?view=checks%2Fjobs#issuecomment-42")

        try open(broker, request: request, grant: grant)

        let url = try XCTUnwrap(opened.urls.first)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(opened.urls.count, 1)
        XCTAssertEqual(components.scheme?.lowercased(), "https")
        XCTAssertEqual(components.host?.lowercased(), "github.com")
        XCTAssertEqual(components.port, 443)
        XCTAssertEqual(components.path, "/owner/repo/pull/7")
        XCTAssertEqual(components.percentEncodedQuery, "view=checks%2Fjobs")
        XCTAssertEqual(components.fragment, "issuecomment-42")
    }

    func testRequestRejectsUnsafeSchemesCredentialsPortsIPAndMalformedHostOrEscapes() {
        let invalid = [
            "", "github.com/owner/repo", "//github.com/owner/repo",
            "http://github.com/owner/repo", "file:///private/file", "javascript:alert(1)",
            "https://user@github.com/", "https://user:secret@github.com/", "https://:secret@github.com/",
            "https://github.com:444/", "https://127.0.0.1/", "https://[::1]/", "https://localhost/",
            "https://github.com./", "https://.github.com/", "https://github..com/",
            "https://github_com/", "https://-github.com/", "https://github-.com/",
            "https://%67ithub.com/", "https://github%2Ecom/",
            "https://github.com/%", "https://github.com/%GG", "https://github.com/%FF"
        ]
        for source in invalid {
            assertError(PluginLinkError.invalidArguments, "Accepted unsafe link: \(source.debugDescription)") {
                _ = try PluginLinkRequest(source: source)
            }
        }
    }

    func testRequestRejectsRawAndPercentEncodedWhitespaceControlsAndBackslashesBeforeURLRepairs() {
        let forbidden = [
            " ", "\t", "\n", "\r", "\u{0000}", "\u{007F}", "\u{0085}", "\u{00A0}", "\\",
            "%20", "%09", "%0A", "%0D", "%00", "%7f", "%C2%85", "%C2%A0", "%5c", "%5C"
        ]
        for value in forbidden {
            let source = "https://github.com/owner/\(value)repo"
            assertError(PluginLinkError.invalidArguments, "URL parsing must not repair \(value.debugDescription).") {
                _ = try PluginLinkRequest(source: source)
            }
        }
        assertError(PluginLinkError.invalidArguments) {
            _ = try PluginLinkRequest(source: " https://github.com/owner/repo")
        }
    }

    func testRequestUsesOriginalUTF8BudgetAndPreservesValidEncodedAndUnicodePaths() throws {
        let prefix = "https://github.com/"
        let exactASCII = prefix + String(repeating: "a", count: 2_048 - prefix.utf8.count)
        XCTAssertEqual(exactASCII.utf8.count, 2_048)
        XCTAssertEqual(try PluginLinkRequest(source: exactASCII).url.absoluteString, exactASCII)
        assertError(PluginLinkError.invalidArguments) {
            _ = try PluginLinkRequest(source: exactASCII + "a")
        }

        let available = 2_048 - prefix.utf8.count
        let exactUnicode = prefix + String(repeating: "界", count: available / 3)
            + String(repeating: "a", count: available % 3)
        XCTAssertEqual(exactUnicode.utf8.count, 2_048)
        let unicodeRequest = try PluginLinkRequest(source: exactUnicode)
        XCTAssertEqual(unicodeRequest.url.path, "/" + String(exactUnicode.dropFirst(prefix.count)))
        assertError(PluginLinkError.invalidArguments) {
            _ = try PluginLinkRequest(source: exactUnicode + "a")
        }

        let encoded = try PluginLinkRequest(source: "https://github.com/owner/%E7%95%8C?ref=feature%2Fone#readme")
        let components = try XCTUnwrap(URLComponents(url: encoded.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/owner/%E7%95%8C")
        XCTAssertEqual(components.percentEncodedQuery, "ref=feature%2Fone")
        XCTAssertEqual(components.fragment, "readme")
    }

    func testExactHostPolicyRejectsSubdomainsSuffixesAndLookalikesWithoutSpendingCooldown() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        var validations = 0
        for source in [
            "https://api.github.com/", "https://www.github.com/", "https://attacker.github.com/",
            "https://github.com.attacker.example/", "https://github-com.example/", "https://example.com/"
        ] {
            let request = try PluginLinkRequest(source: source)
            assertError(PluginLinkError.policyDenied) {
                try broker.open(request: request, pluginID: alpha, authorization: grant.lease,
                                admission: PluginResourceAdmission(), validate: { validations += 1 })
            }
        }
        XCTAssertTrue(opened.urls.isEmpty)
        XCTAssertEqual(validations, 0)
        try open(broker, grant: grant)
        XCTAssertEqual(opened.urls.count, 1)
    }

    func testInvalidAllowlistEntriesDoNotTurnIntoAllowedHosts() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let broker = PluginLinkBroker(allowedHosts: [
            "https://github.com", "github.com.", "%67ithub.com", "127.0.0.1", "github..com", ""
        ], opener: opened.open)
        assertError(PluginLinkError.policyDenied) { try open(broker, grant: grant) }
        XCTAssertTrue(opened.urls.isEmpty)
    }

    func testCooldownIsGlobalAcrossPluginsAndExpiresAtExactlyOneSecond() throws {
        let first = try authorization()
        let second = try authorization(id: "com.example.links.beta")
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let started = clock.instant
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        try open(broker, grant: first)
        assertError(PluginLinkError.rateLimited) { try open(broker, grant: second) }

        clock.instant = started.advanced(by: .seconds(1) - .nanoseconds(1))
        assertError(PluginLinkError.rateLimited) { try open(broker, grant: second) }
        XCTAssertEqual(opened.urls.count, 1)
        clock.instant = started.advanced(by: .seconds(1))
        try open(broker, grant: second)
        XCTAssertEqual(opened.urls.count, 2)
        assertError(PluginLinkError.rateLimited) { try open(broker, grant: first) }
        clock.instant = started.advanced(by: .seconds(2))
        try open(broker, grant: first)
        XCTAssertEqual(opened.urls.count, 3)
    }

    func testFailedSystemOpenStillSpendsCooldownAndCanRetryAfterOneSecond() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        opened.succeeds = false
        let clock = LinkBrokerClock()
        let started = clock.instant
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        assertError(PluginLinkError.openFailed) { try open(broker, grant: grant) }
        XCTAssertEqual(opened.urls.count, 1)

        opened.succeeds = true
        assertError(PluginLinkError.rateLimited) { try open(broker, grant: grant) }
        XCTAssertEqual(opened.urls.count, 1)
        clock.instant = started.advanced(by: .seconds(1))
        try open(broker, grant: grant)
        XCTAssertEqual(opened.urls.count, 2)
    }

    func testLeaseCannotAuthorizeAnotherPluginOrAnotherPermissionAndRejectionDoesNotSpendCooldown() throws {
        let grant = try authorization()
        let network = try authorization(permission: .network)
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        let request = try PluginLinkRequest(source: "https://github.com/owner/repo")
        assertError(PluginPermissionError.undeclared) {
            try broker.open(request: request, pluginID: "com.example.links.beta", authorization: grant.lease,
                            admission: PluginResourceAdmission(), validate: {})
        }
        assertError(PluginPermissionError.undeclared) { try open(broker, grant: network) }
        XCTAssertTrue(opened.urls.isEmpty)
        try open(broker, grant: grant)
        XCTAssertEqual(opened.urls.count, 1)
    }

    func testRevokedLeaseStaysInvalidAfterRegrantButFreshLeaseCanOpenImmediately() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        try grant.permissions.applyHostDecision(decision: .revoked, review: grant.review, permission: .openLinks)
        assertError(PluginPermissionError.revoked) { try open(broker, grant: grant) }
        try grant.permissions.applyHostDecision(decision: .granted, review: grant.review, permission: .openLinks)
        assertError(PluginPermissionError.revoked) { try open(broker, grant: grant) }
        XCTAssertTrue(opened.urls.isEmpty)

        let fresh = try grant.permissions.require(permission: .openLinks, package: grant.package)
        try broker.open(request: PluginLinkRequest(source: "https://github.com/owner/repo"),
                        pluginID: alpha, authorization: fresh, admission: PluginResourceAdmission(), validate: {})
        XCTAssertEqual(opened.urls.count, 1)
    }

    func testRevokedAdmissionAndRejectedFinalValidationCannotOpenOrSpendCooldown() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        let request = try PluginLinkRequest(source: "https://github.com/owner/repo")
        let revoked = PluginResourceAdmission()
        revoked.revoke()
        assertError(PluginResourceError.inactiveExecution) {
            try broker.open(request: request, pluginID: alpha, authorization: grant.lease,
                            admission: revoked, validate: {})
        }
        assertError(PluginLinkError.inactiveExecution) {
            try broker.open(request: request, pluginID: alpha, authorization: grant.lease,
                            admission: PluginResourceAdmission(), validate: { throw PluginLinkError.inactiveExecution })
        }
        XCTAssertTrue(opened.urls.isEmpty)
        try open(broker, grant: grant)
        XCTAssertEqual(opened.urls.count, 1)
    }

    func testFinalValidationCanRevokePermissionOrAdmissionBeforeTheSystemSideEffect() throws {
        for revokePermission in [true, false] {
            let grant = try authorization()
            let opened = LinkBrokerOpenerWitness()
            let broker = PluginLinkBroker(opener: opened.open)
            let request = try PluginLinkRequest(source: "https://github.com/owner/repo")
            let admission = PluginResourceAdmission()
            let operation = {
                try broker.open(request: request, pluginID: self.alpha, authorization: grant.lease,
                                admission: admission, validate: {
                    if revokePermission {
                        try grant.permissions.applyHostDecision(decision: .revoked, review: grant.review,
                                                                permission: .openLinks)
                    } else {
                        admission.revoke()
                    }
                })
            }
            if revokePermission { assertError(PluginPermissionError.revoked) { try operation() } }
            else { assertError(PluginResourceError.inactiveExecution) { try operation() } }
            XCTAssertTrue(opened.urls.isEmpty)
        }
    }

    func testReentrantFinalValidationCannotBypassGlobalCooldown() throws {
        let grant = try authorization()
        let opened = LinkBrokerOpenerWitness()
        let clock = LinkBrokerClock()
        let broker = PluginLinkBroker(now: { clock.instant }, opener: opened.open)
        let request = try PluginLinkRequest(source: "https://github.com/owner/repo")
        let admission = PluginResourceAdmission()
        assertError(PluginLinkError.rateLimited) {
            try broker.open(request: request, pluginID: alpha, authorization: grant.lease,
                            admission: admission, validate: {
                try broker.open(request: request, pluginID: alpha, authorization: grant.lease,
                                admission: admission, validate: {})
            })
        }
        XCTAssertEqual(opened.urls.count, 1,
                       "The nested authorized open spends the slot before the outer attempt resumes.")
    }

    private func authorization(id: String = "com.example.links.alpha",
                               permission: PluginPermission = .openLinks) throws -> LinkBrokerAuthorization {
        let manifest = try PluginManifest(id: id, name: "Link Broker Test", version: SemanticVersion("1.0.0"),
            engine: .javaScriptCore, entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [permission], capabilities: [.handleActions])
        let package = ValidatedPluginPackage(manifest: manifest,
            canonicalRootURL: URL(fileURLWithPath: "/link-broker-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js", entrySource: Data(), regularFileCount: 2, totalFileBytes: 0)
        let permissions = PermissionManager()
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: permission)
        return .init(permissions: permissions, package: package, review: review,
                     lease: try permissions.require(permission: permission, package: package))
    }

    private func open(_ broker: PluginLinkBroker, request: PluginLinkRequest? = nil,
                      grant: LinkBrokerAuthorization) throws {
        try broker.open(request: request ?? PluginLinkRequest(source: "https://github.com/owner/repo"),
                        pluginID: grant.lease.pluginID, authorization: grant.lease,
                        admission: PluginResourceAdmission(), validate: {})
    }

    private func assertError<E: Error & Equatable>(_ expected: E, _ message: String = "",
                                                  file: StaticString = #filePath, line: UInt = #line,
                                                  _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), message, file: file, line: line) {
            XCTAssertEqual($0 as? E, expected, message, file: file, line: line)
        }
    }
}

@MainActor
private struct LinkBrokerAuthorization {
    let permissions: PermissionManager
    let package: ValidatedPluginPackage
    let review: PluginPermissionReview
    let lease: PluginPermissionLease
}

@MainActor
private final class LinkBrokerClock {
    var instant = ContinuousClock.now
}

@MainActor
private final class LinkBrokerOpenerWitness {
    var urls: [URL] = []
    var succeeds = true

    func open(_ url: URL) -> Bool {
        urls.append(url)
        return succeeds
    }
}
