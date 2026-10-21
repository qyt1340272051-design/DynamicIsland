import CoreFoundation
import Foundation
import JavaScriptCore

public nonisolated enum PluginRuntimeState: String, Equatable, Sendable {
    case idle, starting, running, stopping, stopped, failed, tornDown
}

public nonisolated enum PluginRuntimePhase: String, Equatable, Sendable {
    case bootstrap, entry, start, stop, evaluation, bridge
}

public nonisolated enum PluginRuntimeErrorCode: String, Equatable, Sendable {
    case invalidUTF8, contextUnavailable, javaScriptException
    case invalidLifecycleCallback, unsupportedLifecycleReturn
    case compatibilityFailure
}

public nonisolated struct PluginRuntimeFailure: Error, Equatable, Sendable {
    public let phase: PluginRuntimePhase
    public let code: PluginRuntimeErrorCode
    public let message: String
}

public nonisolated enum PluginRuntimeError: Error, Equatable, Sendable {
    case alreadyStarted, inactiveExecution, unsupportedValue
}

public nonisolated struct PluginRuntimeSnapshot: Equatable, Sendable {
    public let state: PluginRuntimeState
    public let lastFailure: PluginRuntimeFailure?
}

/// No JSValue, JSContext or native object crosses the worker boundary.
nonisolated enum PluginJavaScriptValue: Equatable, Sendable {
    case undefined, null, boolean(Bool), number(Double), string(String)
}

/// The synchronous lifecycle facade admits work without waiting for JavaScript.
/// Each instance owns one execution session and one dedicated VM thread.
@MainActor
public final class PluginRuntime: PluginLifecycleRuntime {
    public private(set) var snapshot = PluginRuntimeSnapshot(state: .idle, lastFailure: nil)
    private let package: ValidatedPluginPackage
    private let bridge: PluginJSBridge
    public let diagnostics: PluginDiagnosticsStore
    private var actionSession: PluginActionSession?
    private var countdownSession: PluginCountdownSession?
    private var worker: PluginJavaScriptWorker?
    private var didStart = false
    private var didTeardown = false

    public init(package: ValidatedPluginPackage, bridge: PluginJSBridge? = nil, diagnostics: PluginDiagnosticsStore? = nil) {
        self.package = package
        self.bridge = bridge ?? PluginJSBridge()
        self.diagnostics = diagnostics ?? self.bridge.diagnostics
    }

    public func onStart(context: PluginExecutionContext) throws {
        guard !didStart else { throw PluginRuntimeError.alreadyStarted }
        guard !didTeardown else { throw PluginRuntimeError.inactiveExecution }
        guard context.id == package.manifest.id else { throw PluginExecutionError.sourceMismatch }
        try context.perform {}
        let actionSession = try PluginActionSession(package: package, context: context) { [weak self] delivery in
            self?.worker?.deliverAction(delivery)
        }
        let countdownSession = try PluginCountdownSession(package: package, context: context) { [weak self] delivery in
            self?.worker?.deliverAction(delivery)
        }
        self.actionSession = actionSession
        self.countdownSession = countdownSession
        didStart = true
        snapshot = .init(state: .starting, lastFailure: nil)
        let transport = PluginBridgeTransport(bridge: bridge, package: package, context: context,
                                              actionSession: actionSession, countdownSession: countdownSession)
        let worker = PluginJavaScriptWorker(package: package, transport: transport) { [weak self, context] event in
            Task { @MainActor [weak self] in
                self?.receive(event)
                if case .failed(let failure) = event {
                    if context.reportFailure(failure.phase == .stop ? .stopFailed : .startFailed) {
                        self?.diagnostics.recordRuntimeFailure(pluginID: context.id, failure: failure)
                    }
                }
            }
        }
        self.worker = worker
        worker.start()
    }

    public func onStop(reason: PluginStopReason) throws {
        guard !didTeardown else { return }
        actionSession?.revoke()
        countdownSession?.revoke()
        snapshot = .init(state: .stopping, lastFailure: snapshot.lastFailure)
        worker?.stop(reason: reason)
    }

    public func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
        countdownSession?.discardRecordIfExecutionStillActive()
        actionSession?.revoke()
        countdownSession?.revoke()
        guard let worker else {
            snapshot = .init(state: .tornDown, lastFailure: snapshot.lastFailure)
            return
        }
        snapshot = .init(state: .stopping, lastFailure: snapshot.lastFailure)
        worker.teardown()
    }

    deinit { worker?.teardown() }

    /// Internal diagnostics only; plugin code cannot request arbitrary Host eval.
    func evaluateForTesting(_ source: String) async throws -> PluginJavaScriptValue {
        guard didStart, !didTeardown, let worker else { throw PluginRuntimeError.inactiveExecution }
        return try await withCheckedThrowingContinuation { continuation in
            worker.evaluate(source, continuation: continuation)
        }
    }

    private func receive(_ event: PluginJavaScriptWorker.Event) {
        switch event {
        case .ready:
            guard !didTeardown, snapshot.state == .starting else { return }
            snapshot = .init(state: .running, lastFailure: nil)
        case .failed(let failure):
            actionSession?.revoke()
            countdownSession?.revoke()
            snapshot = .init(state: didTeardown ? snapshot.state : .failed, lastFailure: failure)
        case .stopped:
            guard !didTeardown else { return }
            snapshot = .init(state: .stopped, lastFailure: snapshot.lastFailure)
        case .tornDown:
            snapshot = .init(state: .tornDown, lastFailure: snapshot.lastFailure)
        }
    }
}

/// Only queue admission and revocation use the lock. VM state belongs entirely
/// to threadMain's RunLoop. No main-thread queue.sync or JSValue transfer.
private nonisolated final class PluginJavaScriptWorker: @unchecked Sendable {
    enum Event: Sendable {
        case ready, failed(PluginRuntimeFailure), stopped, tornDown
    }

    private let package: ValidatedPluginPackage
    private let transport: PluginBridgeTransport
    private let sink: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var pending: [() -> Void] = []
    private var actionQueue: [PluginActionDelivery] = []
    private var actionInFlight = false
    private var revoked = false
    private var stopRequested = false
    private var teardownRequested = false
    // Accessed only on the VM's dedicated thread.
    private var engine: PluginJavaScriptEngine?
    private var startedHook = false

    init(package: ValidatedPluginPackage, transport: PluginBridgeTransport, sink: @escaping @Sendable (Event) -> Void) {
        self.package = package
        self.transport = transport
        self.sink = sink
    }

    func start() {
        enqueue { [self] in startOnWorker() }
        let thread = Thread { [self] in threadMain() }
        thread.name = "DynamicIsland.Plugin.\(package.manifest.id)"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop(reason: PluginStopReason) {
        transport.revoke()
        lock.lock()
        guard !stopRequested, !teardownRequested else { lock.unlock(); return }
        stopRequested = true
        revoked = true
        rejectQueuedActionsLocked()
        enqueueLocked { [self] in
            if startedHook, let engine {
                do { try engine.callLifecycle("onStop", phase: .stop, arguments: [reason.rawValue]) }
                catch let failure as PluginRuntimeFailure { sink(.failed(failure)) }
                catch { /* Engine operations use typed failures. */ }
            }
            sink(.stopped)
        }
        lock.unlock()
    }

    func teardown() {
        transport.revoke()
        lock.lock()
        guard !teardownRequested else { lock.unlock(); return }
        teardownRequested = true
        revoked = true
        rejectQueuedActionsLocked()
        enqueueLocked { [self] in
            engine?.dispose()
            engine = nil
            sink(.tornDown)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        lock.unlock()
    }

    func evaluate(_ source: String, continuation: CheckedContinuation<PluginJavaScriptValue, Error>) {
        lock.lock()
        guard !revoked else {
            lock.unlock()
            continuation.resume(throwing: PluginRuntimeError.inactiveExecution)
            return
        }
        enqueueLocked { [self] in
            do {
                guard !isRevoked, let engine else { throw PluginRuntimeError.inactiveExecution }
                let result = try engine.evaluatePrimitive(source)
                guard !isRevoked else { throw PluginRuntimeError.inactiveExecution }
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        lock.unlock()
    }

    /// Actions and countdown completions share this bounded FIFO. Events carry
    /// only data and an actor-isolated Host validity check, never a JS callback.
    func deliverAction(_ delivery: PluginActionDelivery) {
        lock.lock()
        guard !revoked, actionQueue.count + (actionInFlight ? 1 : 0) < 64 else {
            lock.unlock()
            rejectDelivery(delivery)
            return
        }
        actionQueue.append(delivery)
        scheduleNextActionLocked()
        lock.unlock()
    }

    private func scheduleNextActionLocked() {
        guard !revoked, !actionInFlight, !actionQueue.isEmpty else { return }
        actionInFlight = true
        let delivery = actionQueue.removeFirst()
        enqueueLocked { [self] in validateAction(delivery) }
    }

    private func validateAction(_ delivery: PluginActionDelivery) {
        guard !isRevoked else { rejectDelivery(delivery); finishAction(); return }
        Task { @MainActor [weak self] in
            let valid = delivery.isValid()
            self?.receiveValidatedAction(delivery, valid: valid)
        }
    }

    private func receiveValidatedAction(_ delivery: PluginActionDelivery, valid: Bool) {
        lock.lock()
        guard !revoked else {
            actionInFlight = false
            lock.unlock()
            rejectDelivery(delivery)
            return
        }
        enqueueLocked { [self] in
            defer { finishAction() }
            guard valid, !isRevoked, let engine else { rejectDelivery(delivery); return }
            do {
                if try engine.receiveDelivery(delivery) {
                    if let didReceive = delivery.didReceive { Task { @MainActor in didReceive() } }
                } else { rejectDelivery(delivery) }
            }
            catch let failure as PluginRuntimeFailure { rejectDelivery(delivery); fail(failure) }
            catch { rejectDelivery(delivery) }
        }
        lock.unlock()
    }

    private func rejectDelivery(_ delivery: PluginActionDelivery) {
        guard let didNotReceive = delivery.didNotReceive else { return }
        Task { @MainActor in didNotReceive() }
    }

    private func rejectQueuedActionsLocked() {
        let dropped = actionQueue
        actionQueue.removeAll()
        for delivery in dropped { rejectDelivery(delivery) }
    }

    private func finishAction() {
        lock.lock()
        actionInFlight = false
        if revoked { rejectQueuedActionsLocked() }
        else { scheduleNextActionLocked() }
        lock.unlock()
    }

    private var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    private func enqueue(_ work: @escaping () -> Void) {
        lock.lock()
        enqueueLocked(work)
        lock.unlock()
    }

    private func enqueueLocked(_ work: @escaping () -> Void) {
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { autoreleasepool(invoking: work) }
            CFRunLoopWakeUp(runLoop)
        } else {
            pending.append(work)
        }
    }

    private func threadMain() {
        autoreleasepool {
            let loop = CFRunLoopGetCurrent()!
            var sourceContext = CFRunLoopSourceContext(
                version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
                equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in }
            )
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &sourceContext)!
            CFRunLoopAddSource(loop, keepAlive, .defaultMode)
            lock.lock()
            runLoop = loop
            let work = pending
            pending.removeAll()
            for task in work { enqueueLocked(task) }
            lock.unlock()
            CFRunLoopRun()
            engine?.dispose()
            engine = nil
            CFRunLoopRemoveSource(loop, keepAlive, .defaultMode)
            lock.lock()
            runLoop = nil
            lock.unlock()
        }
    }

    private func startOnWorker() {
        guard !isRevoked else { return }
        do {
            let engine = try PluginJavaScriptEngine(package: package) { [weak self] id, json in
                self?.submitBridgeRequest(id: id, json: json)
            }
            self.engine = engine
            guard !isRevoked else { return }
            try engine.loadEntry(package)
            guard !isRevoked else { return }
            startedHook = true
            try engine.callLifecycle("onStart", phase: .start)
            guard !isRevoked else { return }
            sink(.ready)
        } catch let failure as PluginRuntimeFailure {
            fail(failure)
        } catch {
            fail(.init(phase: .bootstrap, code: .contextUnavailable, message: "Runtime initialization failed."))
        }
    }

    private func fail(_ failure: PluginRuntimeFailure) {
        // Close queued Host work as soon as the worker detects failure,
        // before the asynchronous MainActor lifecycle result is delivered.
        transport.revoke()
        lock.lock()
        revoked = true
        rejectQueuedActionsLocked()
        lock.unlock()
        sink(.failed(failure))
    }

    private func submitBridgeRequest(id: Int, json: String) {
        guard !isRevoked else { return }
        let accepted = transport.submit(id: id, json: json) { [weak self] id, response in
            self?.receiveBridgeResponse(id: id, json: response)
        }
        if !accepted {
            receiveBridgeResponse(id: id, json: "{\"ok\":false,\"error\":{\"code\":\"quotaExceeded\",\"message\":\"A Host resource limit was exceeded.\"}}")
        }
    }

    private func receiveBridgeResponse(id: Int, json: String) {
        lock.lock()
        guard !revoked else { lock.unlock(); return }
        enqueueLocked { [self] in
            guard !isRevoked, let engine else { return }
            do { try engine.receiveBridgeResponse(id: id, json: json) }
            catch let failure as PluginRuntimeFailure { fail(failure) }
            catch { /* No native or JavaScript value escapes this worker. */ }
        }
        lock.unlock()
    }
}

/// All methods are called exclusively on the creating worker thread.
private nonisolated final class PluginJavaScriptEngine {
    private var virtualMachine: JSVirtualMachine?
    private var context: JSContext?
    private var exceptionMessage: String?
    private var bridgeReceiver: JSValue?
    private var actionReceiver: JSValue?
    private var countdownReceiver: JSValue?
    private var compatibilityStart: JSValue?
    private var compatibilityStop: JSValue?
    private let submitRequest: @Sendable (Int, String) -> Void

    init(package: ValidatedPluginPackage, submitRequest: @escaping @Sendable (Int, String) -> Void) throws {
        self.submitRequest = submitRequest
        let vm = JSVirtualMachine()
        guard let vm, let context = JSContext(virtualMachine: vm) else {
            throw PluginRuntimeFailure(phase: .bootstrap, code: .contextUnavailable, message: "JavaScript context unavailable.")
        }
        virtualMachine = vm
        self.context = context
        context.name = package.manifest.id
        context.exceptionHandler = { [weak self] _, _ in
            // Exception contents can contain tokens, paths or user resources.
            // Never stringify or inspect the exception, even when primitive.
            self?.exceptionMessage = "JavaScript exception."
        }
        let metadata: [String: Any] = [
            "apiVersion": "1.0.0",
            "plugin": ["id": package.manifest.id, "name": package.manifest.name, "version": package.manifest.version.description]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let json = String(decoding: bytes, as: UTF8.self)
        let nativeKey = "__islandBridge_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let native: @convention(block) (JSValue?, JSValue?) -> Void = { [weak self] id, payload in
            // Exact primitive checks avoid Objective-C argument coercion
            // invoking plugin getters or toString at the native boundary.
            guard let self, let id, id.isNumber, let payload, payload.isString else { return }
            let number = id.toDouble()
            guard number.isFinite, number >= 1, number <= 9_007_199_254_740_991,
                  number.rounded(.towardZero) == number, let json = payload.toString(),
                  json.utf8.count <= 16_384 else { return }
            self.submitRequest(Int(number), json)
        }
        context.setObject(native, forKeyedSubscript: nativeKey as NSString)
        let receivers = try evaluate(
            PluginJSBridgeBootstrap.script(metadataJSON: json, nativeKey: nativeKey), phase: .bootstrap
        )
        bridgeReceiver = receivers?.objectForKeyedSubscript("receiveResponse")
        actionReceiver = receivers?.objectForKeyedSubscript("receiveAction")
        countdownReceiver = receivers?.objectForKeyedSubscript("receiveCountdown")
        guard let bridgeReceiver, let actionReceiver, let countdownReceiver,
              JSObjectIsFunction(context.jsGlobalContextRef, bridgeReceiver.jsValueRef),
              JSObjectIsFunction(context.jsGlobalContextRef, actionReceiver.jsValueRef),
              JSObjectIsFunction(context.jsGlobalContextRef, countdownReceiver.jsValueRef) else {
            throw PluginRuntimeFailure(phase: .bootstrap, code: .contextUnavailable,
                                       message: "Bridge receivers unavailable.")
        }
        if package.manifest.engine == .superIsland {
            let installer = try evaluate(SuperIslandModuleBootstrap.script, phase: .bootstrap)
            guard let installer,
                  JSObjectIsFunction(context.jsGlobalContextRef, installer.jsValueRef),
                  let compatibilityBridge = receivers?.objectForKeyedSubscript("superIslandBridge") else {
                throw PluginRuntimeFailure(phase: .bootstrap, code: .contextUnavailable,
                                           message: "Compatibility installer unavailable.")
            }
            clearException()
            let lifecycle = installer.call(withArguments: [compatibilityBridge])
            try checkException(.bootstrap)
            compatibilityStart = lifecycle?.objectForKeyedSubscript("start")
            compatibilityStop = lifecycle?.objectForKeyedSubscript("stop")
            guard let compatibilityStart, let compatibilityStop,
                  JSObjectIsFunction(context.jsGlobalContextRef, compatibilityStart.jsValueRef),
                  JSObjectIsFunction(context.jsGlobalContextRef, compatibilityStop.jsValueRef) else {
                throw PluginRuntimeFailure(phase: .bootstrap, code: .contextUnavailable,
                                           message: "Compatibility lifecycle unavailable.")
            }
        }
    }

    func loadEntry(_ package: ValidatedPluginPackage) throws {
        guard let source = String(data: package.entrySource, encoding: .utf8) else {
            throw PluginRuntimeFailure(phase: .entry, code: .invalidUTF8, message: "Plugin entry must be UTF-8.")
        }
        let url = URL(string: "dynamic-island-plugin://\(package.manifest.id)/\(package.entryRelativePath)")
        _ = try evaluate(source, phase: .entry, sourceURL: url)
    }

    func callLifecycle(_ name: String, phase: PluginRuntimePhase, arguments: [Any] = []) throws {
        guard let context else { throw PluginRuntimeError.inactiveExecution }
        clearException()
        let callback: JSValue?
        let callbackArguments: [Any]
        if let compatibilityStart, let compatibilityStop {
            callback = name == "onStart" ? compatibilityStart : compatibilityStop
            callbackArguments = []
        } else {
            callback = context.objectForKeyedSubscript(name)
            callbackArguments = arguments
        }
        try checkException(phase)
        guard let callback, !callback.isUndefined else { return }
        guard callback.isObject,
              JSObjectIsFunction(context.jsGlobalContextRef, callback.jsValueRef) else {
            throw PluginRuntimeFailure(phase: phase, code: .invalidLifecycleCallback, message: "\(name) must be a function when present.")
        }
        let result = callback.call(withArguments: callbackArguments)
        try checkException(phase)
        guard result?.isUndefined == true else {
            throw PluginRuntimeFailure(phase: phase, code: .unsupportedLifecycleReturn, message: "\(name) must return undefined; asynchronous lifecycle callbacks are unsupported.")
        }
    }

    func evaluatePrimitive(_ source: String) throws -> PluginJavaScriptValue {
        guard let value = try evaluate(source, phase: .evaluation) else { return .undefined }
        if value.isUndefined { return .undefined }
        if value.isNull { return .null }
        if value.isBoolean { return .boolean(value.toBool()) }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return .string(value.toString()) }
        throw PluginRuntimeError.unsupportedValue
    }

    func receiveBridgeResponse(id: Int, json: String) throws {
        guard let bridgeReceiver else { throw PluginRuntimeError.inactiveExecution }
        clearException()
        _ = bridgeReceiver.call(withArguments: [id, json])
        try checkException(.bridge)
    }

    func receiveDelivery(_ delivery: PluginActionDelivery) throws -> Bool {
        let receiver: JSValue?
        switch delivery.kind {
        case .action: receiver = actionReceiver
        case .countdown: receiver = countdownReceiver
        }
        guard let receiver else { throw PluginRuntimeError.inactiveExecution }
        clearException()
        let result = receiver.call(withArguments: [delivery.registrationID, delivery.eventJSON])
        try checkException(.bridge)
        return delivery.kind == .action || (result?.isBoolean == true && result?.toBool() == true)
    }

    func dispose() {
        bridgeReceiver = nil
        actionReceiver = nil
        countdownReceiver = nil
        compatibilityStart = nil
        compatibilityStop = nil
        context?.exceptionHandler = nil
        context?.exception = nil
        context = nil
        virtualMachine = nil
        exceptionMessage = nil
    }

    private func evaluate(_ source: String, phase: PluginRuntimePhase, sourceURL: URL? = nil) throws -> JSValue? {
        guard let context else { throw PluginRuntimeError.inactiveExecution }
        clearException()
        let result = context.evaluateScript(source, withSourceURL: sourceURL)
        try checkException(phase)
        return result
    }

    private func clearException() {
        exceptionMessage = nil
        context?.exception = nil
    }

    private func checkException(_ phase: PluginRuntimePhase) throws {
        if let exceptionMessage {
            context?.exception = nil
            throw PluginRuntimeFailure(phase: phase, code: .javaScriptException, message: exceptionMessage)
        }
    }
}
