import Foundation

/// One execution observes its Host countdown owner. Revoking this session
/// removes delivery eligibility without changing the business countdown.
@MainActor
final class PluginCountdownSession {
    private nonisolated struct Registration: Sendable {
        let id: String
        let generation = UUID()
    }

    private let context: PluginExecutionContext
    private let broker: PluginCountdownBroker
    private let owner: PluginCountdownOwner?
    private let canHandleCountdown: Bool
    private let deliver: @MainActor (PluginActionDelivery) -> Void
    private var registration: Registration?
    private var observer: UUID?
    private var isRevoked = false

    init(package: ValidatedPluginPackage, context: PluginExecutionContext,
         deliver: @escaping @MainActor (PluginActionDelivery) -> Void) throws {
        guard package.manifest.id == context.id else { throw PluginExecutionError.sourceMismatch }
        self.context = context
        broker = context.countdownBroker
        owner = context.countdownOwner
        canHandleCountdown = package.manifest.capabilities.contains(.countdown)
        self.deliver = deliver
        try context.perform {}
        try context.resourceAdmission.perform {}
        if canHandleCountdown {
            guard let owner, owner.pluginID == context.id else { throw PluginBridgeErrorCode.inactiveExecution }
        }
    }

    /// Re-registering, including the same wire ID, invalidates queued events
    /// captured for the previous registration generation.
    func register(registrationID: String) throws {
        try requireActive()
        guard !registrationID.isEmpty, registrationID.utf8.count <= 80,
              registrationID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                      || byte == 45 || byte == 46 || byte == 95
              }) else { throw PluginBridgeErrorCode.invalidArguments }
        guard let owner else { throw PluginBridgeErrorCode.inactiveExecution }
        let previous = registration
        let previousObserver = observer
        let requested = Registration(id: registrationID)
        registration = requested
        observer = nil
        do {
            let token = try broker.observeCompletions(owner: owner) { [weak self] completion in
                self?.receive(completion)
            }
            // A pending completion can synchronously replace this registration.
            guard !isRevoked, registration?.generation == requested.generation else {
                try? broker.removeCompletionObserver(owner: owner, token: token)
                return
            }
            observer = token
            if let previousObserver {
                try? broker.removeCompletionObserver(owner: owner, token: previousObserver)
            }
        } catch {
            if registration?.generation == requested.generation {
                registration = previous
                observer = previousObserver
            }
            throw error
        }
    }

    func unregister() throws {
        try requireActive()
        registration = nil
        guard let owner, let observer else { return }
        self.observer = nil
        try broker.removeCompletionObserver(owner: owner, token: observer)
    }

    func matches(context: PluginExecutionContext) -> Bool { self.context === context }

    /// Lifecycle invalidates suspended contexts before tearing down their VM.
    /// A direct teardown still holding a live context must drop its alarm.
    func discardRecordIfExecutionStillActive() {
        guard canHandleCountdown, let owner else { return }
        try? context.perform { try broker.clearRecord(owner: owner) }
    }

    func revoke() {
        guard !isRevoked else { return }
        isRevoked = true
        registration = nil
        if let owner, let observer {
            self.observer = nil
            try? broker.removeCompletionObserver(owner: owner, token: observer)
        }
    }

    private func requireActive() throws {
        guard !isRevoked else { throw PluginBridgeErrorCode.inactiveExecution }
        try context.perform {}
        try context.resourceAdmission.perform {}
        guard canHandleCountdown else { throw PluginBridgeErrorCode.capabilityRequired }
    }

    private func receive(_ completion: PluginCountdownCompletion) {
        guard let registration, let owner, completion.owner == owner,
              completion.snapshot.state == .completed,
              let snapshot = currentSnapshot(id: completion.snapshot.id,
                                             generation: completion.snapshot.generation,
                                             registration: registration) else { return }
        let event = PluginBridgeJSON.object([
            "id": .string(snapshot.id), "generation": .string(snapshot.generation.rawValue),
            "state": .string("completed"), "durationMs": .number(Double(snapshot.durationMilliseconds)),
            "remainingMs": .number(0)
        ])
        guard let json = try? event.encodedString(), json.utf8.count <= 1_024 else { return }
        deliver(.init(registrationID: registration.id, eventJSON: json, kind: .countdown,
                      didReceive: { [weak self] in
            guard let self,
                  self.currentSnapshot(id: snapshot.id, generation: snapshot.generation,
                                       registration: registration) != nil,
                  let observer = self.observer else { return }
            _ = try? self.broker.acknowledgeCompletion(owner: owner, id: snapshot.id,
                                                 generation: snapshot.generation, observerToken: observer)
        }, didNotReceive: { [weak self] in
            guard let self,
                  self.currentSnapshot(id: snapshot.id, generation: snapshot.generation,
                                       registration: registration) != nil,
                  let observer = self.observer else { return }
            _ = try? self.broker.releaseCompletionOffer(owner: owner, id: snapshot.id,
                                                  generation: snapshot.generation, observerToken: observer)
        }, isValid: { [weak self] in
            self?.currentSnapshot(id: snapshot.id, generation: snapshot.generation,
                                  registration: registration) != nil
        }))
    }

    private func currentSnapshot(id: String, generation: PluginCountdownGeneration,
                                 registration: Registration) -> PluginCountdownSnapshot? {
        do {
            try requireActive()
            guard self.registration?.generation == registration.generation, let owner,
                  let snapshot = try broker.get(owner: owner, id: id),
                  snapshot.generation == generation, snapshot.state == .completed else { return nil }
            // get may reconcile deadlines and synchronously invoke Host code.
            // Check the context and registration again after that callback.
            try requireActive()
            guard self.registration?.generation == registration.generation else { return nil }
            return snapshot
        } catch { return nil }
    }
}
