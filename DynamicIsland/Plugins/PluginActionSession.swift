import Foundation

/// Only bounded data and a Host admission check cross to the VM worker.
/// The check is the MainActor delivery admission point, not a JS callback.
nonisolated struct PluginActionDelivery: Sendable {
    nonisolated enum Kind: Sendable {
        case action
        case countdown
    }

    let registrationID: String
    let eventJSON: String
    let kind: Kind
    let isValid: @MainActor @Sendable () -> Bool
    let didReceive: (@MainActor @Sendable () -> Void)?
    let didNotReceive: (@MainActor @Sendable () -> Void)?

    init(registrationID: String, eventJSON: String, kind: Kind = .action,
         didReceive: (@MainActor @Sendable () -> Void)? = nil,
         didNotReceive: (@MainActor @Sendable () -> Void)? = nil,
         isValid: @escaping @MainActor @Sendable () -> Bool) {
        self.registrationID = registrationID
        self.eventJSON = eventJSON
        self.kind = kind
        self.isValid = isValid
        self.didReceive = didReceive
        self.didNotReceive = didNotReceive
    }
}

nonisolated enum PluginActionActivationError: Error, Equatable, Sendable {
    case invalidActivation
}

typealias PluginCountdownActivationError = PluginActionActivationError

/// One execution owns one registration table. No function or JSValue is held
/// here, and an old session cannot deliver to a replacement Runtime.
@MainActor
final class PluginActionSession {
    private let context: PluginExecutionContext
    private let canHandleActions: Bool
    private let canActivateCountdown: Bool
    private let canOpenLinks: Bool
    private let now: @MainActor () -> ContinuousClock.Instant
    private let deliver: @MainActor (PluginActionDelivery) -> Void
    private var registrations: [String: String] = [:]
    private var isRevoked = false
    private var userActivation: UserActivation?

    private struct UserActivation {
        let token: String
        let registrationID: String
        let action: RoutedActivityAction
        let expiresAt: ContinuousClock.Instant
        var isConsumed = false
    }

    private enum ActivationPurpose { case countdown, openLink }
    typealias ActivationValidation = @MainActor () throws -> Void

    init(package: ValidatedPluginPackage, context: PluginExecutionContext,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         deliver: @escaping @MainActor (PluginActionDelivery) -> Void) throws {
        guard package.manifest.id == context.id else { throw PluginExecutionError.sourceMismatch }
        self.context = context
        canHandleActions = package.manifest.capabilities.contains(.handleActions)
        canActivateCountdown = package.manifest.capabilities.contains(.countdown)
            && package.manifest.capabilities.contains(.handleActions)
        canOpenLinks = package.manifest.capabilities.contains(.openLinks)
            && package.manifest.capabilities.contains(.handleActions)
        self.now = now
        self.deliver = deliver
        try context.perform {}
        if canHandleActions {
            try context.registerActionHandler { [weak self] action in self?.route(action) }
        }
    }

    func register(actionID: String, registrationID: String) throws {
        try requireActive()
        guard registrations[actionID] != nil || registrations.count < 128 else {
            throw PluginBridgeErrorCode.quotaExceeded
        }
        clearActivation(for: actionID)
        registrations[actionID] = registrationID
    }

    func unregister(actionID: String) throws {
        try requireActive()
        clearActivation(for: actionID)
        registrations.removeValue(forKey: actionID)
    }

    func revoke() {
        isRevoked = true
        userActivation = nil
        registrations.removeAll()
    }

    func matches(context: PluginExecutionContext) -> Bool { self.context === context }

    /// Matching attempts are consumed before any Host callback can reenter.
    /// Random tokens cannot revoke a genuine action's outstanding ticket.
    func consumeCountdownActivation(_ token: String) throws {
        _ = try consumeActivation(token, for: .countdown)
    }

    /// The returned check retains only the consumed action's immutable scope.
    /// It cannot mint or consume another ticket, and is used synchronously at
    /// the final system-open boundary after any Host policy callback.
    func consumeLinkActivation(_ token: String) throws -> ActivationValidation {
        let activation = try consumeActivation(token, for: .openLink)
        return { [weak self] in
            guard let self else { throw PluginCountdownActivationError.invalidActivation }
            try self.validateActivation(activation, for: .openLink)
        }
    }

    private func consumeActivation(_ token: String, for purpose: ActivationPurpose) throws -> UserActivation {
        guard var activation = userActivation, activation.token == token, !activation.isConsumed else {
            throw PluginCountdownActivationError.invalidActivation
        }
        activation.isConsumed = true
        userActivation = activation
        try validateActivation(activation, for: purpose)
        return activation
    }

    private func validateActivation(_ activation: UserActivation, for purpose: ActivationPurpose) throws {
        try requireActive()
        let permitted: Bool
        switch purpose {
        case .countdown: permitted = canActivateCountdown
        case .openLink:
            if case .none = activation.action.value { permitted = canOpenLinks }
            else { permitted = false }
        }
        let instant = now()
        guard permitted,
              userActivation?.token == activation.token, userActivation?.isConsumed == true,
              registrations[activation.action.actionID] == activation.registrationID,
              instant < activation.expiresAt, context.isActionActive(activation.action) else {
            throw PluginCountdownActivationError.invalidActivation
        }
        let finalInstant = now()
        guard !isRevoked,
              userActivation?.token == activation.token, userActivation?.isConsumed == true,
              registrations[activation.action.actionID] == activation.registrationID,
              finalInstant < activation.expiresAt else {
            throw PluginCountdownActivationError.invalidActivation
        }
        try context.perform {}
    }

    private func clearActivation(for actionID: String) {
        if userActivation?.action.actionID == actionID { userActivation = nil }
    }

    private func requireActive() throws {
        guard !isRevoked else { throw PluginBridgeErrorCode.inactiveExecution }
        try context.perform {}
        guard canHandleActions else { throw PluginBridgeErrorCode.capabilityRequired }
    }

    private func route(_ action: RoutedActivityAction) {
        guard !isRevoked, canHandleActions, action.source == context.source,
              let registrationID = registrations[action.actionID], context.isActionActive(action) else { return }
        guard !isRevoked, registrations[action.actionID] == registrationID else { return }
        let prefix = PluginJSBridge.activityID(pluginID: context.id, localID: "")
        guard action.activityID.hasPrefix(prefix) else { return }
        let localID = String(action.activityID.dropFirst(prefix.count))
        guard !localID.isEmpty, localID.utf8.count <= 80,
              localID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }) else { return }
        let payload: PluginBridgeJSON
        switch action.value {
        case .none: payload = .object(["type": .string("none")])
        case .toggle(let value): payload = .object(["type": .string("toggle"), "value": .boolean(value)])
        case .slider(let value), .sliderCommit(let value):
            guard value.isFinite, (0...1).contains(value) else { return }
            payload = .object(["type": .string(action.value.isSliderCommit ? "sliderCommit" : "slider"),
                               "value": .number(value)])
        }
        var fields: [String: PluginBridgeJSON] = [
            "activityID": .string(localID), "actionID": .string(action.actionID), "value": payload
        ]
        // Every newer routed action supersedes the previous ticket. Slider
        // movement never creates one; only a committed interaction can do so.
        userActivation = nil
        if (canActivateCountdown || canOpenLinks), action.value.isCommittedActivation {
            let activation = UserActivation(token: UUID().uuidString, registrationID: registrationID,
                action: action, expiresAt: now().advanced(by: .seconds(5)))
            userActivation = activation
            fields["activation"] = .string(activation.token)
        }
        let event = PluginBridgeJSON.object(fields)
        guard let json = try? event.encodedString(), json.utf8.count <= 1_024 else { return }
        deliver(.init(registrationID: registrationID, eventJSON: json, isValid: { [weak self] in
            guard let self, !self.isRevoked,
                  self.registrations[action.actionID] == registrationID else { return false }
            guard self.context.isActionActive(action) else { return false }
            return !self.isRevoked && self.registrations[action.actionID] == registrationID
        }))
    }
}

private extension IslandRenderActionValue {
    var isCommittedActivation: Bool {
        switch self {
        case .none, .toggle, .sliderCommit: true
        case .slider: false
        }
    }

    var isSliderCommit: Bool {
        if case .sliderCommit = self { return true }
        return false
    }
}
