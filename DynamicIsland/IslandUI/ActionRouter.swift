import Foundation

/// A validated action delivered to the provider that owns the Activity.
/// The provider may publish, update, or end activities from its handler.
public nonisolated struct RoutedActivityAction: Equatable, Sendable {
    public let activityID: String
    public let source: ActivitySource
    public let actionID: String
    public let value: IslandRenderActionValue
}

public nonisolated enum ActionDispatchResult: Equatable, Sendable {
    case handled
    case invalidActionID
    case invalidPayload
    case inactiveActivity
    case undeclaredAction
    case disabledSource
    case unauthorized
    case missingHandler
}

/// Connects a Host-rendered action to the owner of the exact Activity instance
/// the user saw. Handlers stay in the Host, never in serializable Activity data.
@MainActor
public final class ActionRouter {
    public typealias Handler = @MainActor (RoutedActivityAction) -> Void
    public typealias Authorizer = @MainActor (ActivitySource, String) -> Bool
    public typealias SourceEnabled = @MainActor (ActivitySource) -> Bool

    private struct Registration {
        let token: UUID
        let handler: Handler
    }

    private let manager: ActivityManager
    private let sourceEnabled: SourceEnabled
    private let authorizer: Authorizer
    private var registrations: [ActivitySource: Registration] = [:]
    private var disabledSources: Set<ActivitySource> = []

    /// `authorizer` is the Host permission boundary. A later plugin manager
    /// can supply a capability check without changing the action wire format.
    public init(
        manager: ActivityManager,
        sourceEnabled: @escaping SourceEnabled = { _ in true },
        authorizer: @escaping Authorizer = { _, _ in true }
    ) {
        self.manager = manager
        self.sourceEnabled = sourceEnabled
        self.authorizer = authorizer
    }

    /// Return a registration ID so an old provider cannot unregister a newer
    /// handler for the same source after a restart.
    @discardableResult
    public func register(source: ActivitySource, handler: @escaping Handler) -> UUID {
        let token = UUID()
        registrations[source] = Registration(token: token, handler: handler)
        return token
    }

    public func unregister(source: ActivitySource, registration: UUID) {
        guard registrations[source]?.token == registration else { return }
        registrations.removeValue(forKey: source)
    }

    /// A stopped execution session must not retain its handler after a source
    /// is enabled again. Only the Host lifecycle boundary uses this bulk path.
    func unregisterAll(for source: ActivitySource) {
        registrations.removeValue(forKey: source)
    }

    /// Disabling a source invalidates interactions immediately, including
    /// callbacks retained by SwiftUI while a plugin is stopping.
    public func setEnabled(_ enabled: Bool, for source: ActivitySource) {
        if enabled { disabledSources.remove(source) }
        else { disabledSources.insert(source) }
    }

    /// The caller must capture all three identity fields from one
    /// `ActivityManager.currentSnapshot` during rendering. Never look up the
    /// instance token by ID when the button is pressed.
    @discardableResult
    public func dispatch(
        id: String,
        source: ActivitySource,
        instanceToken: ActivityInstanceToken,
        action: IslandRenderAction
    ) -> ActionDispatchResult {
        guard Self.isValidActionID(action.actionID) else { return .invalidActionID }
        guard Self.isValidPayload(action.value) else { return .invalidPayload }
        guard let activity = manager.activeActionActivity(id: id, source: source, instanceToken: instanceToken)
        else { return .inactiveActivity }
        guard activity.actions.contains(where: { $0.id == action.actionID }) else { return .undeclaredAction }
        guard !disabledSources.contains(source), sourceEnabled(source) else { return .disabledSource }
        guard authorizer(source, action.actionID) else { return .unauthorized }
        // A Host authorizer may synchronously change Activity state. Resolve
        // the current instance again just before invoking provider code.
        guard let fresh = manager.activeActionActivity(id: id, source: source, instanceToken: instanceToken),
              fresh.actions.contains(where: { $0.id == action.actionID }) else { return .inactiveActivity }
        guard !disabledSources.contains(source), sourceEnabled(source) else { return .disabledSource }
        guard let handler = registrations[source]?.handler else { return .missingHandler }
        handler(RoutedActivityAction(activityID: id, source: source, actionID: action.actionID, value: action.value))
        return .handled
    }

    private static func isValidActionID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= IslandNode.Limits.maxActionIDBytes else { return false }
        return id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) ||
            (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 58 || byte == 95
        }
    }

    private static func isValidPayload(_ value: IslandRenderActionValue) -> Bool {
        switch value {
        case .none, .toggle: true
        case .slider(let number), .sliderCommit(let number):
            number.isFinite && (0...1).contains(number)
        }
    }
}
