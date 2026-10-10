import Foundation

/// One FIFO per execution session. No JavaScript reference enters this queue.
/// MainActor work is asynchronous; the VM never waits for the UI thread.
nonisolated final class PluginBridgeTransport: @unchecked Sendable {
    private struct Request: Sendable {
        let id: Int
        let json: String
        let reply: @Sendable (Int, String) -> Void
    }

    private let lock = NSLock()
    private let process: @MainActor @Sendable (String, @escaping @Sendable (String) -> Void) async -> Void
    private let storageAdmission: PluginStorageAdmission
    private let networkAdmission: PluginNetworkAdmission
    private var requests: [Request] = []
    private var draining = false
    private var revoked = false

    @MainActor
    init(bridge: PluginJSBridge, package: ValidatedPluginPackage, context: PluginExecutionContext,
         actionSession: PluginActionSession? = nil) {
        storageAdmission = context.storageAdmission
        networkAdmission = context.networkAdmission
        process = { await bridge.dispatch($0, package: package, context: context, actionSession: actionSession, reply: $1) }
    }

    @discardableResult
    func submit(id: Int, json: String, reply: @escaping @Sendable (Int, String) -> Void) -> Bool {
        lock.lock()
        guard !revoked, requests.count < 64 else { lock.unlock(); return false }
        requests.append(.init(id: id, json: json, reply: reply))
        let shouldDrain = !draining
        draining = true
        lock.unlock()
        if shouldDrain { Task { await drain() } }
        return true
    }

    func revoke() {
        lock.lock()
        revoked = true
        requests.removeAll()
        lock.unlock()
        networkAdmission.revoke()
        storageAdmission.revoke()
    }

    private func next() -> Request? {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked, !requests.isEmpty else {
            draining = false
            return nil
        }
        return requests.removeFirst()
    }

    private var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    private func drain() async {
        while let request = next() {
            await processIfActive(request)
        }
    }

    @MainActor
    private func processIfActive(_ request: Request) async {
        // Check after the actor hop, covering requests already dequeued when
        // direct teardown revokes a still-running lifecycle context.
        guard !isRevoked else { return }
        await process(request.json) { [weak self] response in
            guard let self, !self.isRevoked else { return }
            request.reply(request.id, response)
        }
    }
}
