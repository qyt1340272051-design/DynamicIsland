import CoreFoundation
import Foundation
import JavaScriptCore

public nonisolated enum PluginRuntimeState: String, Equatable, Sendable {
    case idle, starting, running, stopping, stopped, failed, tornDown
}

public nonisolated enum PluginRuntimePhase: String, Equatable, Sendable {
    case bootstrap, entry, start, stop, evaluation
}

public nonisolated enum PluginRuntimeErrorCode: String, Equatable, Sendable {
    case invalidUTF8, contextUnavailable, javaScriptException
    case invalidLifecycleCallback, unsupportedLifecycleReturn
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
    private var worker: PluginJavaScriptWorker?
    private var didStart = false
    private var didTeardown = false

    public init(package: ValidatedPluginPackage) {
        self.package = package
    }

    public func onStart(context: PluginExecutionContext) throws {
        guard !didStart else { throw PluginRuntimeError.alreadyStarted }
        guard !didTeardown else { throw PluginRuntimeError.inactiveExecution }
        guard context.id == package.manifest.id else { throw PluginExecutionError.sourceMismatch }
        try context.perform {}
        didStart = true
        snapshot = .init(state: .starting, lastFailure: nil)
        let worker = PluginJavaScriptWorker(package: package) { [weak self, context] event in
            Task { @MainActor [weak self] in
                self?.receive(event)
                if case .failed(let failure) = event {
                    context.reportFailure(failure.phase == .stop ? .stopFailed : .startFailed)
                }
            }
        }
        self.worker = worker
        worker.start()
    }

    public func onStop(reason: PluginStopReason) throws {
        guard !didTeardown else { return }
        snapshot = .init(state: .stopping, lastFailure: snapshot.lastFailure)
        worker?.stop(reason: reason)
    }

    public func teardown() {
        guard !didTeardown else { return }
        didTeardown = true
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
    private let sink: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var pending: [() -> Void] = []
    private var revoked = false
    private var stopRequested = false
    private var teardownRequested = false
    // Accessed only on the VM's dedicated thread.
    private var engine: PluginJavaScriptEngine?
    private var startedHook = false

    init(package: ValidatedPluginPackage, sink: @escaping @Sendable (Event) -> Void) {
        self.package = package
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
        lock.lock()
        guard !stopRequested, !teardownRequested else { lock.unlock(); return }
        stopRequested = true
        revoked = true
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
        lock.lock()
        guard !teardownRequested else { lock.unlock(); return }
        teardownRequested = true
        revoked = true
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
            let engine = try PluginJavaScriptEngine(package: package)
            self.engine = engine
            guard !isRevoked else { return }
            try engine.loadEntry(package)
            guard !isRevoked else { return }
            startedHook = true
            try engine.callLifecycle("onStart", phase: .start)
            guard !isRevoked else { return }
            sink(.ready)
        } catch let failure as PluginRuntimeFailure {
            sink(.failed(failure))
        } catch {
            sink(.failed(.init(phase: .bootstrap, code: .contextUnavailable, message: "Runtime initialization failed.")))
        }
    }
}

/// All methods are called exclusively on the creating worker thread.
private nonisolated final class PluginJavaScriptEngine {
    private var virtualMachine: JSVirtualMachine?
    private var context: JSContext?
    private var exceptionMessage: String?

    init(package: ValidatedPluginPackage) throws {
        let vm = JSVirtualMachine()
        guard let vm, let context = JSContext(virtualMachine: vm) else {
            throw PluginRuntimeFailure(phase: .bootstrap, code: .contextUnavailable, message: "JavaScript context unavailable.")
        }
        virtualMachine = vm
        self.context = context
        context.name = package.manifest.id
        context.exceptionHandler = { [weak self] _, exception in
            // Reading object.message/stack/then or coercing an object can run
            // arbitrary getters. Only primitive string exceptions are read.
            self?.exceptionMessage = exception?.isString == true
                ? String((exception?.toString() ?? "JavaScript exception.").prefix(256))
                : "JavaScript exception."
        }
        let metadata: [String: Any] = [
            "apiVersion": "1.0.0",
            "plugin": ["id": package.manifest.id, "name": package.manifest.name, "version": package.manifest.version.description]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        let json = String(decoding: bytes, as: UTF8.self)
        _ = try evaluate("""
        (() => {
            const metadata = \(json);
            const plugin = Object.freeze(Object.assign(Object.create(null), metadata.plugin));
            const island = Object.freeze(Object.assign(Object.create(null), {apiVersion: metadata.apiVersion, plugin}));
            Object.defineProperty(globalThis, 'island', {value: island, writable: false, configurable: false, enumerable: true});
        })();
        """, phase: .bootstrap)
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
        let callback = context.objectForKeyedSubscript(name)
        try checkException(phase)
        guard let callback, !callback.isUndefined else { return }
        guard callback.isObject,
              JSObjectIsFunction(context.jsGlobalContextRef, callback.jsValueRef) else {
            throw PluginRuntimeFailure(phase: phase, code: .invalidLifecycleCallback, message: "\(name) must be a function when present.")
        }
        let result = callback.call(withArguments: arguments)
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

    func dispose() {
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
