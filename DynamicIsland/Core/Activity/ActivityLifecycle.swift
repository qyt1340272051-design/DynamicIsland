import Foundation

/// Presentation state is separate from data lifetime: dismissal hides an
/// activity, while ending removes that event from the active set.
public nonisolated struct ActivityLifecycle: Codable, Equatable, Sendable {
    public nonisolated enum State: String, Codable, Sendable {
        case queued
        case presented
        case background
        case dismissed
        case ended
    }

    public nonisolated enum Policy: String, Codable, Sendable {
        case transient
        case persistent
        case progress
        case critical

        public var isInterruptible: Bool { self != .critical }
    }

    public nonisolated enum Event: Sendable {
        case present
        case moveToBackground
        case dismiss
        case expire
        case sourceEnd
    }

    public nonisolated enum TransitionError: Error, Sendable {
        case invalid(state: State, event: Event)
    }

    public private(set) var state: State
    public let policy: Policy

    public init(state: State = .queued, policy: Policy) {
        self.state = state
        self.policy = policy
    }

    public var isTerminal: Bool { state == .ended }

    public func applying(_ event: Event) throws -> Self {
        var next = self
        switch event {
        case .present:
            guard state == .queued || state == .background else {
                throw TransitionError.invalid(state: state, event: event)
            }
            next.state = .presented
        case .moveToBackground:
            guard state == .queued || state == .presented else {
                throw TransitionError.invalid(state: state, event: event)
            }
            next.state = .background
        case .dismiss:
            guard state == .queued || state == .presented || state == .background else {
                throw TransitionError.invalid(state: state, event: event)
            }
            next.state = .dismissed
        case .expire, .sourceEnd:
            guard state != .ended else {
                throw TransitionError.invalid(state: state, event: event)
            }
            next.state = .ended
        }
        return next
    }
}
