import Foundation

/// Only bounded data and a Host admission check cross to the VM worker.
/// The check is the MainActor delivery admission point, not a JS callback.
nonisolated struct PluginActionDelivery: Sendable {
    let registrationID: String
    let eventJSON: String
    let isValid: @MainActor @Sendable () -> Bool
}

/// One execution owns one registration table. No function or JSValue is held
/// here, and an old session cannot deliver to a replacement Runtime.
@MainActor
final class PluginActionSession {
    private let context: PluginExecutionContext
    private let canHandleActions: Bool
    private let deliver: @MainActor (PluginActionDelivery) -> Void
    private var registrations: [String: String] = [:]
    private var isRevoked = false

    init(package: ValidatedPluginPackage, context: PluginExecutionContext,
         deliver: @escaping @MainActor (PluginActionDelivery) -> Void) throws {
        guard package.manifest.id == context.id else { throw PluginExecutionError.sourceMismatch }
        self.context = context
        canHandleActions = package.manifest.capabilities.contains(.handleActions)
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
        registrations[actionID] = registrationID
    }

    func unregister(actionID: String) throws {
        try requireActive()
        registrations.removeValue(forKey: actionID)
    }

    func revoke() {
        isRevoked = true
        registrations.removeAll()
    }

    func matches(context: PluginExecutionContext) -> Bool { self.context === context }

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
        let event = PluginBridgeJSON.object([
            "activityID": .string(localID), "actionID": .string(action.actionID), "value": payload
        ])
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
    var isSliderCommit: Bool {
        if case .sliderCommit = self { return true }
        return false
    }
}
