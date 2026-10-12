import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginRuntimeTests: XCTestCase {
    func testMinimalIslandContainsImmutableManifestIdentityAndNoNativeCapabilities() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let package = try makePackage(name: "音乐 \"测试\" \\ island")
        let runtime = fixture.load(package)
        try await waitUntil { runtime.snapshot.state == .running }

        let identity = try await runtime.evaluateForTesting("island.plugin.id + '|' + island.plugin.name + '|' + island.plugin.version")
        XCTAssertEqual(identity, .string("com.example.alpha|音乐 \"测试\" \\ island|1.2.3"))
        let bootstrap = try await runtime.evaluateForTesting("""
            island.apiVersion === '1.0.0' &&
            Object.isFrozen(island) && Object.isFrozen(island.plugin) &&
            Object.getPrototypeOf(island) === null &&
            Object.getPrototypeOf(island.plugin) === null
            """)
        XCTAssertEqual(bootstrap, .boolean(true))
        let capabilities = try await runtime.evaluateForTesting("""
            typeof island.log === 'function' && Object.isFrozen(island.activity) &&
            Object.isFrozen(island.storage) && Object.isFrozen(island.actions) &&
            ['FileManager', 'NSFileManager', 'URLSession', 'NSURLSession', 'NSWorkspace',
             'ObjC', 'require', 'process', 'fetch', 'setTimeout', 'clearTimeout']
                .every(key => typeof globalThis[key] === 'undefined')
            """)
        XCTAssertEqual(capabilities, .boolean(true))
    }

    func testPluginCannotReplaceIslandOrChangeItsIdentity() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: """
            globalThis.originalIsland = island;
            globalThis.island = { apiVersion: 'fake' };
            island.apiVersion = 'fake';
            island.plugin.id = 'com.example.other';
            try { Object.setPrototypeOf(island.plugin, { injected: true }); } catch (_) {}
            """))
        try await waitUntil { runtime.snapshot.state == .running }

        let unchanged = try await runtime.evaluateForTesting("""
            island === originalIsland && island.apiVersion === '1.0.0' &&
            island.plugin.id === 'com.example.alpha' &&
            typeof island.plugin.injected === 'undefined' &&
            Object.getOwnPropertyDescriptor(globalThis, 'island').writable === false &&
            Object.getOwnPropertyDescriptor(globalThis, 'island').configurable === false
            """)
        XCTAssertEqual(unchanged, .boolean(true))
    }

    func testEachPluginHasIndependentGlobalsAndBuiltInPrototypes() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let alpha = fixture.load(try makePackage(source: "globalThis.onlyAlpha = 73; Object.prototype.alpha = true;"))
        let beta = fixture.load(try makePackage(id: "com.example.beta", source: "globalThis.onlyBeta = 'beta';"))
        try await waitUntil { alpha.snapshot.state == .running && beta.snapshot.state == .running }

        let alphaValue = try await alpha.evaluateForTesting("onlyAlpha")
        let betaIsolation = try await beta.evaluateForTesting("typeof onlyAlpha === 'undefined' && typeof ({}).alpha === 'undefined'")
        let alphaIsolation = try await alpha.evaluateForTesting("typeof onlyBeta === 'undefined'")
        XCTAssertEqual(alphaValue, .number(73))
        XCTAssertEqual(betaIsolation, .boolean(true))
        XCTAssertEqual(alphaIsolation, .boolean(true))
    }

    func testEntryExceptionStopsOnlyItsOwnerAndAnotherPluginRemainsUsable() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let alpha = fixture.load(try makePackage(source: "throw new Error('alpha failed');"))
        let beta = fixture.load(try makePackage(id: "com.example.beta", source: "globalThis.answer = 42;"))
        try await waitUntil {
            alpha.snapshot.lastFailure != nil &&
            fixture.bridge.snapshot(id: "com.example.alpha")?.state == .stopped &&
            beta.snapshot.state == .running
        }

        XCTAssertEqual(alpha.snapshot.lastFailure?.phase, .entry)
        XCTAssertEqual(alpha.snapshot.lastFailure?.code, .javaScriptException)
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.lastFailure, .startFailed)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        XCTAssertTrue(fixture.bridge.allowsExecution(id: "com.example.beta"))
        let answer = try await beta.evaluateForTesting("answer")
        XCTAssertEqual(answer, .number(42))
    }

    func testBusyPluginDoesNotBlockMainActorOrAnotherVirtualMachine() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        // A finite busy loop exercises VM lock independence without leaving
        // an uninterruptible script behind in the XCTest process.
        let alpha = fixture.load(try makePackage(source: """
            const finish = Date.now() + 1800;
            while (Date.now() < finish) {}
            """))
        let beta = fixture.load(try makePackage(id: "com.example.beta", source: "globalThis.answer = 42;"))
        try await waitUntil(timeout: 1.2) { beta.snapshot.state == .running }

        XCTAssertEqual(alpha.snapshot.state, .starting)
        let answer = try await beta.evaluateForTesting("answer")
        XCTAssertEqual(answer, .number(42))
        try await waitUntil { alpha.snapshot.state == .running }
    }

    func testClassicEntryAndOptionalOnStartExecuteInOrder() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: """
            globalThis.events = ['entry'];
            globalThis.onStart = function() { events.push('start'); };
            globalThis.onStop = function(reason) { events.push('stop:' + reason); };
            """))
        try await waitUntil { runtime.snapshot.state == .running }

        let events = try await runtime.evaluateForTesting("events.join(',')")
        XCTAssertEqual(events, .string("entry,start"))
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .running)
        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testEntryWithoutLifecycleCallbacksIsSupported() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.loaded = true;"))
        try await waitUntil { runtime.snapshot.state == .running }

        let loaded = try await runtime.evaluateForTesting("loaded")
        XCTAssertEqual(loaded, .boolean(true))
        try fixture.bridge.stop(id: "com.example.alpha")
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testPrimitiveEvaluationCopiesValuesAndRejectsObjectsWithoutCoercion() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage())
        try await waitUntil { runtime.snapshot.state == .running }

        let expressions: [(String, PluginJavaScriptValue)] = [
            ("undefined", .undefined), ("null", .null), ("true", .boolean(true)),
            ("73.5", .number(73.5)), ("'音乐'", .string("音乐"))
        ]
        for (expression, expected) in expressions {
            let value = try await runtime.evaluateForTesting(expression)
            XCTAssertEqual(value, expected)
        }
        do {
            _ = try await runtime.evaluateForTesting("""
                globalThis.coercions = 0;
                ({ toString() { coercions += 1; throw new Error('must not coerce'); } })
                """)
            XCTFail("Objects must remain on the JavaScript worker.")
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .unsupportedValue)
        }
        let coercions = try await runtime.evaluateForTesting("coercions")
        XCTAssertEqual(coercions, .number(0))
        XCTAssertEqual(runtime.snapshot.state, .running)
    }

    func testOneRuntimeCannotStartTwice() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.starts = 1;"))
        let context = try XCTUnwrap(fixture.factory.contexts.last)
        try await waitUntil { runtime.snapshot.state == .running }

        XCTAssertThrowsError(try runtime.onStart(context: context)) { error in
            XCTAssertEqual(error as? PluginRuntimeError, .alreadyStarted)
        }
        let starts = try await runtime.evaluateForTesting("starts")
        XCTAssertEqual(starts, .number(1))
    }

    func testInvalidUTF8IsRejectedBeforeScriptExecution() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(entrySource: Data([0xC3, 0x28])))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .entry)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .invalidUTF8)
        try await waitUntil { fixture.bridge.snapshot(id: "com.example.alpha")?.state == .stopped }
    }

    func testEntrySyntaxErrorIsReportedAsEntryFailure() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "function {"))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .entry)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
    }

    func testOnStartExceptionRevokesExecutionAndKeepsFailureSnapshot() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.onStart = function() { throw new Error('start failed'); };"))
        try await waitUntil { fixture.bridge.snapshot(id: "com.example.alpha")?.state == .stopped }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .start)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        try await assertInactive(runtime)
    }

    func testNonfunctionOnStartIsRejected() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.onStart = 42;"))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .start)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .invalidLifecycleCallback)
    }

    func testPromiseReturnedByOnStartIsRejected() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.onStart = function() { return Promise.resolve(); };"))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .start)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .unsupportedLifecycleReturn)
    }

    func testLifecycleReturnValidationDoesNotReadThenGetter() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: """
            globalThis.onStart = function() {
                return Object.defineProperty({}, 'then', {
                    get() { throw new Error('then getter must not execute'); }
                });
            };
            """))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .start)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .unsupportedLifecycleReturn)
    }

    func testExceptionDiagnosticsDoNotInvokePluginMessageStackOrToStringGetters() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: """
            const exception = Object.create(null);
            for (const key of ['message', 'stack', 'toString']) {
                Object.defineProperty(exception, key, {
                    get() { throw new Error('unsafe diagnostic getter: ' + key); }
                });
            }
            throw exception;
            """))
        try await waitUntil { runtime.snapshot.lastFailure != nil }

        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .entry)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
        XCTAssertFalse(runtime.snapshot.lastFailure?.message.contains("unsafe diagnostic getter") ?? true)
    }

    func testOnStopExceptionStillReleasesExecutionAndRetainsStopFailure() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.onStop = function() { throw new Error('stop failed'); };"))
        try await waitUntil { runtime.snapshot.state == .running }

        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .disabled)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        try await waitUntil { runtime.snapshot.state == .tornDown && runtime.snapshot.lastFailure != nil }
        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .stop)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .javaScriptException)
        try await waitUntil { fixture.bridge.snapshot(id: "com.example.alpha")?.lastFailure == .stopFailed }
        try await assertInactive(runtime)
    }

    func testNonfunctionOnStopIsRejectedDuringStopWithoutReopeningExecution() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.onStop = {};"))
        try await waitUntil { runtime.snapshot.state == .running }

        try fixture.bridge.stop(id: "com.example.alpha")
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertEqual(runtime.snapshot.lastFailure?.phase, .stop)
        XCTAssertEqual(runtime.snapshot.lastFailure?.code, .invalidLifecycleCallback)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
    }

    func testRuntimeExecutesValidatedBytesWithoutReopeningEntryPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PluginRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.js")
        try Data("throw new Error('path contents are not validated');".utf8).write(to: file)
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.answer = 73;", root: root))
        try await waitUntil { runtime.snapshot.state == .running }

        let answer = try await runtime.evaluateForTesting("answer")
        XCTAssertEqual(answer, .number(73))
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testDisablingAndReenablingCreatesFreshRuntimeGlobals() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let old = fixture.load(try makePackage(source: "globalThis.starts = (globalThis.starts || 0) + 1;"))
        try await waitUntil { old.snapshot.state == .running }
        _ = try await old.evaluateForTesting("globalThis.previousSession = true")

        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: true)
        let current = try XCTUnwrap(fixture.factory.runtimes.last)
        XCTAssertFalse(old === current)
        try await waitUntil { current.snapshot.state == .running }

        let fresh = try await current.evaluateForTesting("starts === 1 && typeof previousSession === 'undefined'")
        XCTAssertEqual(fresh, .boolean(true))
        try await assertInactive(old)
    }

    func testOldPendingEntryFailureCannotStopReplacementPluginSession() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let old = fixture.load(try makePackage(source: """
            const finish = Date.now() + 250;
            while (Date.now() < finish) {}
            throw new Error('previous generation failed');
            """))
        let current = fixture.load(try makePackage(source: "globalThis.answer = 99;"))
        try await waitUntil { current.snapshot.state == .running && old.snapshot.state == .tornDown }

        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .running)
        XCTAssertNil(fixture.bridge.snapshot(id: "com.example.alpha")?.lastFailure)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        let answer = try await current.evaluateForTesting("answer")
        XCTAssertEqual(answer, .number(99))
        try await assertInactive(old)
    }

    func testOldDelayedOnStopFailureCannotOverwriteReplacementSession() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let old = fixture.load(try makePackage(source: """
            globalThis.onStop = function() {
                const finish = Date.now() + 250;
                while (Date.now() < finish) {}
                throw new Error('previous stop failed');
            };
            """))
        try await waitUntil { old.snapshot.state == .running }

        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        let current = fixture.load(try makePackage(source: "globalThis.answer = 99;"))
        try await waitUntil {
            current.snapshot.state == .running && old.snapshot.state == .tornDown && old.snapshot.lastFailure != nil
        }

        XCTAssertEqual(old.snapshot.lastFailure?.phase, .stop)
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .running)
        XCTAssertNil(fixture.bridge.snapshot(id: "com.example.alpha")?.lastFailure)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        let answer = try await current.evaluateForTesting("answer")
        XCTAssertEqual(answer, .number(99))
    }

    func testRevokedContextCannotReportFailureAgainstCurrentSession() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let old = fixture.load(try makePackage())
        let oldContext = try XCTUnwrap(fixture.factory.contexts.last)
        try await waitUntil { old.snapshot.state == .running }
        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: true)
        let current = try XCTUnwrap(fixture.factory.runtimes.last)
        try await waitUntil { current.snapshot.state == .running }

        XCTAssertFalse(oldContext.reportFailure(.startFailed))
        XCTAssertFalse(oldContext.reportFailure(.stopFailed))
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .running)
        XCTAssertNil(fixture.bridge.snapshot(id: "com.example.alpha")?.lastFailure)
        XCTAssertTrue(fixture.bridge.allowsExecution(id: "com.example.alpha"))
    }

    func testSleepSuspendsRealRuntimeAndResumeCreatesFreshSession() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let old = fixture.load(try makePackage(source: "globalThis.starts = (globalThis.starts || 0) + 1;"))
        try await waitUntil { old.snapshot.state == .running }
        _ = try await old.evaluateForTesting("globalThis.oldSession = true")

        fixture.bridge.setEnvironment(isSleeping: true, isLowBattery: false)
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .suspended)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        try await assertInactive(old)
        try await waitUntil { old.snapshot.state == .tornDown }
        fixture.bridge.setEnvironment(isSleeping: false, isLowBattery: false)
        let current = try XCTUnwrap(fixture.factory.runtimes.last)
        XCTAssertFalse(old === current)
        try await waitUntil { current.snapshot.state == .running }

        let fresh = try await current.evaluateForTesting("starts === 1 && typeof oldSession === 'undefined'")
        XCTAssertEqual(fresh, .boolean(true))
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .running)
    }

    func testManagerLoadEnableReloadDisableAndUninstallDriveRealRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginRuntimeManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let configuration = PluginManagerConfiguration(rootDirectoryURL: root, hostVersion: try SemanticVersion("0.6.0"))
        let manager = PluginManager(configuration: configuration, lifecycleHandler: fixture.bridge)
        let initial = await manager.discover()
        XCTAssertTrue(initial.failures.isEmpty)
        let packageURL = configuration.installedDirectoryURL.appendingPathComponent("Alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let package = try makePackage(source: "globalThis.answer = 73;", root: packageURL)
        try package.manifest.encodeJSON().write(to: packageURL.appendingPathComponent("manifest.json"))
        try package.entrySource.write(to: packageURL.appendingPathComponent("index.js"))

        _ = try await manager.load(at: packageURL)
        XCTAssertEqual(fixture.bridge.snapshot(id: package.manifest.id)?.state, .disabled)
        XCTAssertTrue(fixture.factory.runtimes.isEmpty)
        _ = try await manager.enable(id: package.manifest.id)
        let first = try XCTUnwrap(fixture.factory.runtimes.last)
        try await waitUntil { first.snapshot.state == .running }
        let initialAnswer = try await first.evaluateForTesting("answer")
        XCTAssertEqual(initialAnswer, .number(73))

        try Data("globalThis.answer = 74;".utf8).write(to: packageURL.appendingPathComponent("index.js"))
        _ = try await manager.reload(id: package.manifest.id)
        let second = try XCTUnwrap(fixture.factory.runtimes.last)
        XCTAssertFalse(first === second)
        try await waitUntil { second.snapshot.state == .running && first.snapshot.state == .tornDown }
        let updatedAnswer = try await second.evaluateForTesting("answer")
        XCTAssertEqual(updatedAnswer, .number(74))
        try await assertInactive(first)

        _ = try await manager.disable(id: package.manifest.id)
        XCTAssertEqual(fixture.bridge.snapshot(id: package.manifest.id)?.state, .disabled)
        try await waitUntil { second.snapshot.state == .tornDown }
        _ = try await manager.enable(id: package.manifest.id)
        let third = try XCTUnwrap(fixture.factory.runtimes.last)
        try await waitUntil { third.snapshot.state == .running }
        _ = try await manager.uninstall(id: package.manifest.id)

        XCTAssertNil(fixture.bridge.snapshot(id: package.manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        let plugins = await manager.plugins()
        XCTAssertTrue(plugins.isEmpty)
        try await assertInactive(third)
        try await waitUntil { third.snapshot.state == .tornDown }
    }

    func testTeardownRevokesAdmissionSynchronouslyAndIsIdempotent() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage())
        try await waitUntil { runtime.snapshot.state == .running }

        runtime.teardown()
        runtime.teardown()
        try await assertInactive(runtime)
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testImmediateDisableRevokesStartupBeforeReadiness() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage(source: "globalThis.loaded = true;"))

        fixture.bridge.pluginDidChangeEnablement(id: "com.example.alpha", isEnabled: false)
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .disabled)
        XCTAssertFalse(fixture.bridge.allowsExecution(id: "com.example.alpha"))
        try await assertInactive(runtime)
        try await waitUntil { runtime.snapshot.state == .tornDown }
        XCTAssertEqual(fixture.bridge.snapshot(id: "com.example.alpha")?.state, .disabled)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testTeardownResumesPendingEvaluationWithInactiveExecution() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        let runtime = fixture.load(try makePackage())
        try await waitUntil { runtime.snapshot.state == .running }
        var requested = false
        let evaluation = Task { @MainActor in
            requested = true
            return try await runtime.evaluateForTesting("""
                const finish = Date.now() + 300;
                while (Date.now() < finish) {}
                42;
                """)
        }
        // The task sets the marker and synchronously enqueues its evaluation
        // before yielding the MainActor at the continuation await.
        try await waitUntil { requested }
        runtime.teardown()

        do {
            _ = try await evaluation.value
            XCTFail("A queued or executing result must be discarded after revocation.")
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .inactiveExecution)
        }
        try await waitUntil { runtime.snapshot.state == .tornDown }
    }

    func testUnloadedRuntimeIsReleasedAfterWorkerCleanup() async throws {
        let fixture = RuntimeTestFixture()
        defer { fixture.shutdown() }
        var retained: PluginRuntime? = fixture.load(try makePackage())
        let weakRuntime = RuntimeTestWeakReference(retained)
        try await waitUntil { retained?.snapshot.state == .running }

        fixture.bridge.pluginWillUnload(id: "com.example.alpha")
        try await waitUntil { retained?.snapshot.state == .tornDown }
        fixture.factory.runtimes.removeAll()
        retained = nil
        try await waitUntil { weakRuntime.value == nil }
        XCTAssertNil(weakRuntime.value)
    }

    // MARK: - Helpers

    private func makePackage(
        id: String = "com.example.alpha",
        name: String = "Runtime Test",
        source: String = "",
        entrySource: Data? = nil,
        root: URL? = nil
    ) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(
            id: id,
            name: name,
            version: SemanticVersion("1.2.3"),
            engine: .javaScriptCore,
            entry: "index.js",
            minimumHostVersion: SemanticVersion("0.6.0"),
            permissions: [],
            capabilities: []
        )
        let bytes = entrySource ?? Data(source.utf8)
        return ValidatedPluginPackage(
            manifest: manifest,
            canonicalRootURL: root ?? URL(fileURLWithPath: "/runtime-tests/\(id)", isDirectory: true),
            entryRelativePath: "index.js",
            entrySource: bytes,
            regularFileCount: 2,
            totalFileBytes: UInt64(bytes.count)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Runtime did not reach the expected state before the deadline.", file: file, line: line)
                throw RuntimeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func assertInactive(
        _ runtime: PluginRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            _ = try await runtime.evaluateForTesting("42")
            XCTFail("A revoked Runtime must reject new JavaScript work.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .inactiveExecution, file: file, line: line)
        }
    }
}

@MainActor
private final class RuntimeTestFixture {
    let factory = RuntimeTestFactory()
    let bridge: PluginLifecycleBridge

    init() {
        let manager = ActivityManager()
        let router = ActionRouter(manager: manager)
        let factory = factory
        bridge = PluginLifecycleBridge(activityManager: manager, actionRouter: router, runtimeFactory: { package in
            let runtime = PluginRuntime(package: package)
            factory.runtimes.append(runtime)
            return RuntimeTestForwarder(runtime: runtime, factory: factory)
        })
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        bridge.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }

    func shutdown() { bridge.shutdown() }
}

@MainActor
private final class RuntimeTestFactory {
    var runtimes: [PluginRuntime] = []
    var contexts: [PluginExecutionContext] = []
}

@MainActor
private final class RuntimeTestWeakReference {
    weak var value: PluginRuntime?

    init(_ value: PluginRuntime?) { self.value = value }
}

@MainActor
private final class RuntimeTestForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime
    let factory: RuntimeTestFactory

    init(runtime: PluginRuntime, factory: RuntimeTestFactory) {
        self.runtime = runtime
        self.factory = factory
    }

    func onStart(context: PluginExecutionContext) throws {
        factory.contexts.append(context)
        try runtime.onStart(context: context)
    }

    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private enum RuntimeTestError: Error {
    case timedOut
}
