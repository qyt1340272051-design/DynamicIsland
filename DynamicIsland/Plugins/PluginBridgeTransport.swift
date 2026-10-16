import Foundation

/// Two bounded FIFOs per execution session: storage and interactive requests.
/// Storage keeps its read/write order without holding time-sensitive actions
/// behind disk I/O. Await a storage Promise when another operation depends on it.
/// No JavaScript reference enters either queue; the VM never waits for UI work.
nonisolated final class PluginBridgeTransport: @unchecked Sendable {
    private enum Lane: Hashable, Sendable { case storage, interactive }
    private struct Request: Sendable {
        let admissionID = UUID()
        let id: Int
        let json: String
        let reply: @Sendable (Int, String) -> Void
    }

    private let lock = NSLock()
    private let process: @MainActor @Sendable (String, @escaping @Sendable (String) -> Void) async -> Void
    private let storageAdmission: PluginStorageAdmission
    private let networkAdmission: PluginNetworkAdmission
    private let resourceAdmission: PluginResourceAdmission
    private var requests: [Lane: [Request]] = [:]
    private var draining: Set<Lane> = []
    private var admissions: Set<UUID> = []
    private var revoked = false

    @MainActor
    init(bridge: PluginJSBridge, package: ValidatedPluginPackage, context: PluginExecutionContext,
         actionSession: PluginActionSession? = nil, countdownSession: PluginCountdownSession? = nil) {
        storageAdmission = context.storageAdmission
        networkAdmission = context.networkAdmission
        resourceAdmission = context.resourceAdmission
        process = {
            await bridge.dispatch($0, package: package, context: context,
                                  actionSession: actionSession, countdownSession: countdownSession, reply: $1)
        }
    }

    @discardableResult
    func submit(id: Int, json: String, reply: @escaping @Sendable (Int, String) -> Void) -> Bool {
        let lane = Self.lane(for: json)
        lock.lock()
        guard !revoked, admissions.count < 64 else { lock.unlock(); return false }
        let request = Request(id: id, json: json, reply: reply)
        admissions.insert(request.admissionID)
        requests[lane, default: []].append(request)
        let shouldDrain = draining.insert(lane).inserted
        lock.unlock()
        if shouldDrain { Task { await drain(lane) } }
        return true
    }

    private static func lane(for json: String) -> Lane {
        // Classification grants no capability or authorization. The Bridge
        // independently parses and validates the complete request in both lanes.
        guard case .object(let fields)? = try? PluginBridgeJSON.parse(json),
              case .string(let method)? = fields["method"],
              ["storage.get", "storage.set", "storage.remove", "storage.clear"].contains(method)
        else { return .interactive }
        return .storage
    }

    func revoke() {
        lock.lock()
        revoked = true
        requests.removeAll()
        admissions.removeAll()
        lock.unlock()
        resourceAdmission.revoke()
        networkAdmission.revoke()
        storageAdmission.revoke()
    }

    private func next(_ lane: Lane) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, requests[lane]?.isEmpty == false else {
            draining.remove(lane)
            return nil
        }
        return requests[lane]!.removeFirst()
    }

    private var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    private func drain(_ lane: Lane) async {
        while let request = next(lane) {
            await processIfActive(request)
            // Network / file / refresh dispatch returns after admission and
            // replies later. Immediate replies release before reaching the VM.
            release(request)
        }
    }

    private func release(_ request: Request) {
        lock.withLock { _ = admissions.remove(request.admissionID) }
    }

    @MainActor
    private func processIfActive(_ request: Request) async {
        // Check after the actor hop, covering requests already dequeued when
        // direct teardown revokes a still-running lifecycle context.
        guard !isRevoked else { return }
        await process(request.json) { [weak self] response in
            guard let self, !self.isRevoked else { return }
            // A settled SDK Promise may immediately submit its next request.
            // Free its Host slot first; the drain's fallback is idempotent.
            self.release(request)
            request.reply(request.id, response)
        }
    }
}
