import Foundation

/// A request names one Host-admitted Activity instance. It is not a command
/// to expand the island, change the selected surface, or end the Activity.
public nonisolated struct PresentationRequest: Equatable, Sendable {
    public let snapshot: ActivitySnapshot
    public let autoDismiss: Bool

    public init(snapshot: ActivitySnapshot, autoDismiss: Bool = true) {
        self.snapshot = snapshot
        self.autoDismiss = autoDismiss
    }
}

/// A policy result is data only. Acceptance reserves a bounded opportunity
/// within the existing queue; it does not bypass source limits or dwell time.
public nonisolated struct PresentationDecision: Equatable, Sendable {
    public nonisolated enum Status: String, Codable, Sendable {
        case accepted, degraded, rejected
    }

    public nonisolated enum Reason: String, Codable, Sendable {
        case granted, boundedDuration, alreadyGranted, withdrawn, noRequest
        case hostUnavailable, userSelection, busy, statusPriority
        case staleInstance, invalidActivity, contextBudgetUsed
    }

    public let status: Status
    public let reason: Reason
    public let expiresAt: Date?

    public init(status: Status, reason: Reason, expiresAt: Date? = nil) {
        self.status = status
        self.reason = reason
        self.expiresAt = expiresAt
    }
}
