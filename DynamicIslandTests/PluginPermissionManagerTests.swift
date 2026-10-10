import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginPermissionManagerTests: XCTestCase {
    private let alpha = "com.example.permissions.alpha"
    private let beta = "com.example.permissions.beta"

    func testDeclarationsCreateRequestedReviewWithoutGrantingAccess() throws {
        let permissions = PermissionManager()
        let package = try package(permissions: [.network, .localStorage], capabilities: [.publishActivity, .localStorage])
        let review = permissions.request(package: package)
        let snapshot = try permissions.snapshot(package: package)

        XCTAssertEqual(review.id, alpha)
        XCTAssertEqual(review.name, "Permission Test")
        XCTAssertEqual(review.version, try SemanticVersion("1.0.0"))
        XCTAssertEqual(Set(review.permissions), [.network, .localStorage])
        XCTAssertEqual(Set(review.capabilities), [.publishActivity, .localStorage])
        XCTAssertEqual(snapshot.review, review)
        XCTAssertEqual(snapshot.states, [.network: .requested, .localStorage: .requested])
        assertPermissionFailure(.notGranted) { try permissions.require(permission: .localStorage, package: package) }
        assertPermissionFailure(.notGranted) { try permissions.require(permission: "network", package: package) }
    }

    func testHostDecisionsEnforceAllFourStatesAndRejectDeniedOrRevokedLeases() throws {
        let permissions = PermissionManager()
        let package = try package()
        let review = permissions.request(package: package)
        XCTAssertEqual(try permissions.state(permission: .localStorage, package: package), .requested)
        assertPermissionFailure(.notGranted) { try permissions.require(permission: .localStorage, package: package) }

        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        XCTAssertEqual(try permissions.state(permission: "storage.local", package: package), .granted)
        let lease = try permissions.require(permission: .localStorage, package: package)
        XCTAssertEqual(try lease.perform { "authorized" }, "authorized")

        try permissions.applyHostDecision(decision: .denied, review: review, permission: .localStorage)
        XCTAssertEqual(try permissions.state(permission: .localStorage, package: package), .denied)
        assertPermissionFailure(.denied) { try permissions.require(permission: .localStorage, package: package) }
        assertPermissionFailure(.revoked) { try lease.perform { XCTFail("A denied lease ran its body.") } }

        try permissions.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
        XCTAssertEqual(try permissions.state(permission: .localStorage, package: package), .revoked)
        assertPermissionFailure(.revoked) { try permissions.require(permission: .localStorage, package: package) }
    }

    func testUnknownAndUndeclaredPermissionsFailClosedEvenAfterAnotherGrant() throws {
        let permissions = PermissionManager()
        let package = try package()
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)

        for name in ["", "future.admin", "storage", "STORAGE.LOCAL", "network"] {
            assertPermissionFailure(.undeclared) { try permissions.require(permission: name, package: package) }
            assertPermissionFailure(.undeclared) { try permissions.state(permission: name, package: package) }
        }
        assertPermissionFailure(.undeclared) { try permissions.require(permission: .network, package: package) }
        assertPermissionFailure(.undeclared) {
            try permissions.applyHostDecision(decision: .granted, review: review, permission: .network)
        }
        XCTAssertEqual(try permissions.snapshot(package: package).states, [.localStorage: .granted])
    }

    func testDecisionsAndReviewScopesAreIsolatedBetweenPluginIdentities() throws {
        let permissions = PermissionManager()
        let first = try package(id: alpha)
        let second = try package(id: beta)
        let firstReview = permissions.request(package: first)
        let secondReview = permissions.request(package: second)
        XCTAssertNotEqual(firstReview.scope, secondReview.scope)
        try permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .localStorage)
        try permissions.applyHostDecision(decision: .denied, review: secondReview, permission: .localStorage)

        XCTAssertEqual(try permissions.state(permission: .localStorage, package: first), .granted)
        assertPermissionFailure(.denied) { try permissions.require(permission: .localStorage, package: second) }
        let firstLease = try permissions.require(permission: .localStorage, package: first)
        try permissions.applyHostDecision(decision: .revoked, review: secondReview, permission: .localStorage)
        XCTAssertEqual(try firstLease.perform { 42 }, 42)
        XCTAssertEqual(try permissions.state(permission: .localStorage, package: second), .revoked)
    }

    func testRepeatedRequestAndDeclarationReorderingPreserveDecisionsAndLeases() throws {
        let permissions = PermissionManager()
        let original = try package(permissions: [.network, .localStorage], capabilities: [.publishActivity, .localStorage])
        let review = permissions.request(package: original)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        try permissions.applyHostDecision(decision: .denied, review: review, permission: .network)
        let lease = try permissions.require(permission: .localStorage, package: original)
        let reordered = try package(permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity])

        XCTAssertEqual(permissions.request(package: original), review)
        XCTAssertEqual(permissions.request(package: reordered), review)
        XCTAssertEqual(try permissions.snapshot(package: reordered).states, [.localStorage: .granted, .network: .denied])
        XCTAssertEqual(try lease.perform { "same authorization" }, "same authorization")
    }

    func testManifestChangesResetDecisionsAndInvalidateOldReviewsAndLeases() throws {
        let original = try package(permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity])
        let replacements = [
            try package(name: "Renamed Permission Test", permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity]),
            try package(version: "1.0.1", permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity]),
            try package(entry: "next.js", permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity]),
            try package(minimumHostVersion: "0.6.1", permissions: [.localStorage, .network], capabilities: [.localStorage, .publishActivity]),
            try package(permissions: [.localStorage], capabilities: [.localStorage, .publishActivity]),
            try package(permissions: [.localStorage, .network], capabilities: [.localStorage])
        ]
        for replacement in replacements {
            let permissions = PermissionManager()
            let oldReview = permissions.request(package: original)
            try permissions.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
            let lease = try permissions.require(permission: .localStorage, package: original)
            let nextReview = permissions.request(package: replacement)

            XCTAssertNotEqual(nextReview.scope, oldReview.scope)
            XCTAssertEqual(try permissions.state(permission: .localStorage, package: replacement), .requested)
            assertPermissionFailure(.notGranted) { try permissions.require(permission: .localStorage, package: replacement) }
            assertPermissionFailure(.staleReview) {
                try permissions.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
            }
            assertPermissionFailure(.staleReview) { try permissions.snapshot(package: original) }
            assertPermissionFailure(.revoked) { try lease.perform { XCTFail("Replacement manifest retained an old lease.") } }
        }
    }

    func testEntrySourceChangeWithSameLengthInvalidatesAuthorizationAndReturningBytesDoesNotRestoreIt() throws {
        let permissions = PermissionManager()
        let original = try package(source: "const secret = 1;")
        let replacement = try package(source: "const secret = 2;")
        XCTAssertEqual(original.entrySource.count, replacement.entrySource.count)
        let oldReview = permissions.request(package: original)
        try permissions.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        let oldLease = try permissions.require(permission: .localStorage, package: original)
        let nextReview = permissions.request(package: replacement)

        XCTAssertNotEqual(nextReview.scope, oldReview.scope)
        assertPermissionFailure(.staleReview) {
            try permissions.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        }
        assertPermissionFailure(.revoked) { try oldLease.perform { XCTFail("Changed code retained an old lease.") } }
        let returnedReview = permissions.request(package: original)
        XCTAssertNotEqual(returnedReview.scope, oldReview.scope)
        XCTAssertNotEqual(returnedReview.scope, nextReview.scope)
        assertPermissionFailure(.notGranted) { try permissions.require(permission: .localStorage, package: original) }
    }

    func testReviewFromAnotherManagerCannotAuthorizeAnIdenticalPackage() throws {
        let package = try package()
        let first = PermissionManager()
        let foreignReview = first.request(package: package)
        let second = PermissionManager()
        let localReview = second.request(package: package)

        XCTAssertNotEqual(foreignReview.scope, localReview.scope)
        assertPermissionFailure(.staleReview) {
            try second.applyHostDecision(decision: .granted, review: foreignReview, permission: .localStorage)
        }
        assertPermissionFailure(.notGranted) { try second.require(permission: .localStorage, package: package) }
    }

    func testNewHostSessionStartsRequestedAfterAnEarlierSessionGrantedAccess() throws {
        let package = try package()
        let previous = PermissionManager()
        let oldReview = previous.request(package: package)
        try previous.applyHostDecision(decision: .granted, review: oldReview, permission: .localStorage)
        let nextSession = PermissionManager()
        let nextReview = nextSession.request(package: package)

        XCTAssertNotEqual(nextReview.scope, oldReview.scope)
        XCTAssertEqual(try nextSession.state(permission: .localStorage, package: package), .requested)
        assertPermissionFailure(.notGranted) { try nextSession.require(permission: .localStorage, package: package) }
    }

    func testEveryRegrantCreatesANewGenerationAndOldLeasesNeverRevive() throws {
        let permissions = PermissionManager()
        let package = try package()
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let first = try permissions.require(permission: .localStorage, package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let second = try permissions.require(permission: .localStorage, package: package)
        assertPermissionFailure(.revoked) { try first.perform { XCTFail("Repeated grant revived its previous generation.") } }
        XCTAssertEqual(try second.perform { 2 }, 2)

        try permissions.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let third = try permissions.require(permission: .localStorage, package: package)
        assertPermissionFailure(.revoked) { try first.perform { XCTFail("First lease revived after regrant.") } }
        assertPermissionFailure(.revoked) { try second.perform { XCTFail("Revoked lease revived after regrant.") } }
        XCTAssertEqual(try third.perform { 3 }, 3)
    }

    func testRevokeAllImmediatelyInvalidatesLeasesAcrossPlugins() throws {
        let permissions = PermissionManager()
        let packages = [try package(id: alpha), try package(id: beta)]
        var leases: [PluginPermissionLease] = []
        for package in packages {
            let review = permissions.request(package: package)
            try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
            leases.append(try permissions.require(permission: .localStorage, package: package))
        }
        permissions.revokeAll()

        for package in packages {
            XCTAssertEqual(try permissions.state(permission: .localStorage, package: package), .revoked)
            assertPermissionFailure(.revoked) { try permissions.require(permission: .localStorage, package: package) }
        }
        for lease in leases {
            assertPermissionFailure(.revoked) { try lease.perform { XCTFail("Shutdown retained an authorization.") } }
        }
    }

    func testUnregisterInvalidatesOldScopeAndReregistrationRequiresAnotherDecision() throws {
        let permissions = PermissionManager()
        let first = try package(id: alpha)
        let second = try package(id: beta)
        let firstReview = permissions.request(package: first)
        let secondReview = permissions.request(package: second)
        try permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .localStorage)
        try permissions.applyHostDecision(decision: .granted, review: secondReview, permission: .localStorage)
        let firstLease = try permissions.require(permission: .localStorage, package: first)
        let secondLease = try permissions.require(permission: .localStorage, package: second)
        permissions.unregister(pluginID: alpha)

        assertPermissionFailure(.staleReview) { try permissions.snapshot(package: first) }
        assertPermissionFailure(.revoked) { try firstLease.perform { XCTFail("Unregistered plugin retained its lease.") } }
        XCTAssertEqual(try secondLease.perform { "beta" }, "beta")
        let nextReview = permissions.request(package: first)
        XCTAssertNotEqual(nextReview.scope, firstReview.scope)
        assertPermissionFailure(.staleReview) {
            try permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .localStorage)
        }
        assertPermissionFailure(.notGranted) { try permissions.require(permission: .localStorage, package: first) }
    }

    func testRealJavaScriptAllStorageMethodsRequireGrantAndFailImmediatelyAfterRevocationWhileVMRuns() async throws {
        let store = PluginStorage()
        try await store.set(pluginID: alpha, key: "secret", value: .string("Host secret"))
        let fixture = PermissionRuntimeFixture(store: store)
        defer { fixture.shutdown() }
        let package = try package(source: """
            function onStart() { globalThis.started = true; }
            async function probe() {
                const results = [];
                const operations = [() => island.storage.get('secret'),
                    () => island.storage.set('blocked', 'replacement'),
                    () => island.storage.remove('secret'), () => island.storage.clear()];
                for (const operation of operations) {
                    try { results.push({code:'ok', value:await operation()}); }
                    catch (error) { results.push({code:error.code}); }
                }
                globalThis.codes = results.map(result => result.code).join(',');
                globalThis.readValue = results[0].code === 'ok' ? results[0].value : null;
                globalThis.done = true;
            }
            """)
        let runtime = fixture.load(package)
        try await marker(runtime, "started")
        let review = try fixture.permissions.snapshot(package: package).review

        try await runProbe(runtime)
        try await assertJavaScript(runtime, "codes", equals: .string(Array(repeating: "permissionNotGranted", count: 4).joined(separator: ",")))
        try await assertJavaScript(runtime, "readValue", equals: .null)
        try await assertStoredValue(store, pluginID: alpha, key: "secret", equals: .string("Host secret"))
        try await assertStoredValue(store, pluginID: alpha, key: "blocked", equals: .null)

        try fixture.permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        try await runProbe(runtime)
        try await assertJavaScript(runtime, "codes", equals: .string("ok,ok,ok,ok"))
        try await assertJavaScript(runtime, "readValue", equals: .string("Host secret"))
        try await assertStoredValue(store, pluginID: alpha, key: "secret", equals: .null)
        try await assertStoredValue(store, pluginID: alpha, key: "blocked", equals: .null)

        try await store.set(pluginID: alpha, key: "secret", value: .string("Private after revoke"))
        try fixture.permissions.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
        try await runProbe(runtime)
        try await assertJavaScript(runtime, "codes", equals: .string(Array(repeating: "permissionRevoked", count: 4).joined(separator: ",")))
        try await assertJavaScript(runtime, "readValue", equals: .null)
        try await assertStoredValue(store, pluginID: alpha, key: "secret", equals: .string("Private after revoke"))
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertEqual(fixture.lifecycle.snapshot(id: alpha)?.state, .running)
        XCTAssertNil(runtime.snapshot.lastFailure)
    }

    func testRealJavaScriptTwoPluginsCannotGrantThemselvesOrShareTheOtherPluginsDecision() async throws {
        let store = PluginStorage()
        let fixture = PermissionRuntimeFixture(store: store)
        defer { fixture.shutdown() }
        let source = """
            function onStart() {
                globalThis.started = true;
                globalThis.permissionAPIAbsent = typeof island.permissions === 'undefined' &&
                    typeof island.requestPermission === 'undefined' && typeof island.applyHostDecision === 'undefined';
            }
            function probe() {
                island.storage.set('same', island.plugin.id).then(() => {
                    globalThis.code = 'ok'; globalThis.done = true;
                }, error => { globalThis.code = error.code; globalThis.done = true; });
            }
            """
        let first = try package(id: alpha, source: source)
        let second = try package(id: beta, source: source)
        let firstRuntime = fixture.load(first)
        let secondRuntime = fixture.load(second)
        try await marker(firstRuntime, "started")
        try await marker(secondRuntime, "started")
        let firstReview = try fixture.permissions.snapshot(package: first).review
        let secondReview = try fixture.permissions.snapshot(package: second).review

        for runtime in [firstRuntime, secondRuntime] {
            try await assertJavaScript(runtime, "permissionAPIAbsent", equals: .boolean(true))
            try await runProbe(runtime)
            try await assertJavaScript(runtime, "code", equals: .string("permissionNotGranted"))
        }
        try fixture.permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .localStorage)
        try await runProbe(firstRuntime)
        try await assertJavaScript(firstRuntime, "code", equals: .string("ok"))
        try await runProbe(secondRuntime)
        try await assertJavaScript(secondRuntime, "code", equals: .string("permissionNotGranted"))
        try fixture.permissions.applyHostDecision(decision: .denied, review: secondReview, permission: .localStorage)
        try await runProbe(secondRuntime)
        try await assertJavaScript(secondRuntime, "code", equals: .string("permissionDenied"))
        try fixture.permissions.applyHostDecision(decision: .granted, review: secondReview, permission: .localStorage)
        try await runProbe(secondRuntime)
        try await assertJavaScript(secondRuntime, "code", equals: .string("ok"))

        try fixture.permissions.applyHostDecision(decision: .revoked, review: firstReview, permission: .localStorage)
        try await runProbe(firstRuntime)
        try await assertJavaScript(firstRuntime, "code", equals: .string("permissionRevoked"))
        try await runProbe(secondRuntime)
        try await assertJavaScript(secondRuntime, "code", equals: .string("ok"))
        try fixture.permissions.applyHostDecision(decision: .revoked, review: secondReview, permission: .localStorage)
        try await runProbe(secondRuntime)
        try await assertJavaScript(secondRuntime, "code", equals: .string("permissionRevoked"))
        try await assertStoredValue(store, pluginID: alpha, key: "same", equals: .string(alpha))
        try await assertStoredValue(store, pluginID: beta, key: "same", equals: .string(beta))
        for runtime in [firstRuntime, secondRuntime] {
            XCTAssertEqual(runtime.snapshot.state, .running)
            XCTAssertNil(runtime.snapshot.lastFailure)
        }
    }

    func testRevocationDuringPreparedSetRemoveAndClearPreventsCommitEvenAfterRegrant() async throws {
        for operation in ["set", "remove", "clear"] {
            let workspace = try PermissionStorageWorkspace()
            defer { workspace.remove() }
            let baseline = PluginStorage(configuration: workspace.configuration)
            try await baseline.set(pluginID: alpha, key: "secret", value: .string("previous"))
            let before = try Data(contentsOf: workspace.file(alpha))
            let permissions = PermissionManager()
            let package = try package()
            let review = permissions.request(package: package)
            try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
            let lease = try permissions.require(permission: .localStorage, package: package)
            let gate = PermissionStorageIOGate()
            defer { gate.release() }
            let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
            let task = Task {
                switch operation {
                case "set": try await store.set(pluginID: alpha, key: "secret", value: .string("replacement"), authorization: lease)
                case "remove": try await store.remove(pluginID: alpha, key: "secret", authorization: lease)
                default: try await store.clear(pluginID: alpha, authorization: lease)
                }
            }
            try await waitForIO(gate)
            XCTAssertFalse(gate.wasOnMainThread, operation)
            try permissions.applyHostDecision(decision: .revoked, review: review, permission: .localStorage)
            try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
            gate.release()
            await assertAsyncPermissionFailure(.revoked) { try await task.value }

            XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), before, operation)
            try await assertStoredValue(baseline, pluginID: alpha, key: "secret", equals: .string("previous"))
            let nextLease = try permissions.require(permission: .localStorage, package: package)
            try await store.set(pluginID: alpha, key: "fresh", value: .boolean(true), authorization: nextLease)
            try await assertStoredValue(baseline, pluginID: alpha, key: "fresh", equals: .boolean(true))
        }
    }

    func testRevocationDuringGetPreventsReturningPrivateData() async throws {
        let workspace = try PermissionStorageWorkspace()
        defer { workspace.remove() }
        let baseline = PluginStorage(configuration: workspace.configuration)
        try await baseline.set(pluginID: alpha, key: "secret", value: .string("must not be delivered"))
        let permissions = PermissionManager()
        let package = try package()
        let review = permissions.request(package: package)
        try permissions.applyHostDecision(decision: .granted, review: review, permission: .localStorage)
        let lease = try permissions.require(permission: .localStorage, package: package)
        let gate = PermissionStorageIOGate()
        defer { gate.release() }
        let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
        let task = Task { try await store.get(pluginID: alpha, key: "secret", authorization: lease) }
        try await waitForIO(gate)
        XCTAssertFalse(gate.wasOnMainThread)
        permissions.revokeAll()
        gate.release()
        await assertAsyncPermissionFailure(.revoked) { try await task.value }
        try await assertStoredValue(baseline, pluginID: alpha, key: "secret", equals: .string("must not be delivered"))

        for operation in ["get", "set", "remove", "clear"] {
            let earlyGate = PermissionStorageIOGate()
            defer { earlyGate.release() }
            let protected = PluginStorage(configuration: workspace.configuration, ioObserver: { earlyGate.observe() })
            await assertAsyncPermissionFailure(.revoked) {
                switch operation {
                case "get": _ = try await protected.get(pluginID: self.alpha, key: "secret", authorization: lease)
                case "set": try await protected.set(pluginID: self.alpha, key: "secret", value: .null, authorization: lease)
                case "remove": try await protected.remove(pluginID: self.alpha, key: "secret", authorization: lease)
                default: try await protected.clear(pluginID: self.alpha, authorization: lease)
                }
            }
            XCTAssertFalse(earlyGate.hasEntered, "Already revoked \(operation) reached disk I/O.")
        }
    }

    func testStorageRejectsWrongPermissionAndCrossPluginLeasesBeforeIOWithoutSideEffects() async throws {
        let workspace = try PermissionStorageWorkspace()
        defer { workspace.remove() }
        let baseline = PluginStorage(configuration: workspace.configuration)
        try await baseline.set(pluginID: alpha, key: "secret", value: .string("alpha private"))
        try await baseline.set(pluginID: beta, key: "secret", value: .string("beta private"))
        let firstBytes = try Data(contentsOf: workspace.file(alpha))
        let secondBytes = try Data(contentsOf: workspace.file(beta))
        let permissions = PermissionManager()
        let first = try package(id: alpha, permissions: [.network, .localStorage])
        let second = try package(id: beta)
        let firstReview = permissions.request(package: first)
        let secondReview = permissions.request(package: second)
        try permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .network)
        try permissions.applyHostDecision(decision: .granted, review: firstReview, permission: .localStorage)
        try permissions.applyHostDecision(decision: .granted, review: secondReview, permission: .localStorage)
        let networkLease = try permissions.require(permission: .network, package: first)
        let firstStorageLease = try permissions.require(permission: .localStorage, package: first)
        let secondStorageLease = try permissions.require(permission: .localStorage, package: second)
        XCTAssertEqual(networkLease.pluginID, alpha)
        XCTAssertEqual(networkLease.permission, .network)
        XCTAssertEqual(firstStorageLease.pluginID, alpha)
        XCTAssertEqual(firstStorageLease.permission, .localStorage)

        let gate = PermissionStorageIOGate()
        // Mark unexpected I/O without blocking a failing test.
        gate.release()
        let store = PluginStorage(configuration: workspace.configuration, ioObserver: { gate.observe() })
        for binding in [(pluginID: alpha, lease: networkLease), (pluginID: beta, lease: firstStorageLease)] {
            for operation in ["get", "set", "remove", "clear"] {
                await assertAsyncPermissionFailure(.undeclared) {
                    switch operation {
                    case "get": _ = try await store.get(pluginID: binding.pluginID, key: "secret", authorization: binding.lease)
                    case "set": try await store.set(pluginID: binding.pluginID, key: "secret", value: .string("replacement"), authorization: binding.lease)
                    case "remove": try await store.remove(pluginID: binding.pluginID, key: "secret", authorization: binding.lease)
                    default: try await store.clear(pluginID: binding.pluginID, authorization: binding.lease)
                    }
                }
                XCTAssertFalse(gate.hasEntered, "Incorrectly bound \(operation) reached disk I/O.")
            }
        }
        XCTAssertEqual(try Data(contentsOf: workspace.file(alpha)), firstBytes)
        XCTAssertEqual(try Data(contentsOf: workspace.file(beta)), secondBytes)

        XCTAssertEqual(try firstStorageLease.perform(pluginID: alpha, permission: .localStorage) { "bound" }, "bound")
        try await store.set(pluginID: alpha, key: "secret", value: .string("alpha granted"), authorization: firstStorageLease)
        try await store.set(pluginID: beta, key: "secret", value: .string("beta granted"), authorization: secondStorageLease)
        let firstValue = try await store.get(pluginID: alpha, key: "secret", authorization: firstStorageLease)
        let secondValue = try await store.get(pluginID: beta, key: "secret", authorization: secondStorageLease)
        XCTAssertEqual(firstValue, .string("alpha granted"))
        XCTAssertEqual(secondValue, .string("beta granted"))
        XCTAssertTrue(gate.hasEntered)
    }

    private func package(
        id: String = "com.example.permissions.alpha", name: String = "Permission Test",
        version: String = "1.0.0", entry: String = "index.js", minimumHostVersion: String = "0.6.0",
        source: String = "", permissions: [PluginPermission] = [.localStorage],
        capabilities: [PluginCapability] = [.localStorage]
    ) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(
            id: id, name: name, version: SemanticVersion(version), engine: .javaScriptCore,
            entry: entry, minimumHostVersion: SemanticVersion(minimumHostVersion),
            permissions: permissions, capabilities: capabilities
        )
        let bytes = Data(source.utf8)
        return .init(manifest: manifest,
                     canonicalRootURL: URL(fileURLWithPath: "/permission-tests/\(id)", isDirectory: true),
                     entryRelativePath: entry, entrySource: bytes, regularFileCount: 2, totalFileBytes: UInt64(bytes.count))
    }

    private func assertPermissionFailure<T>(
        _ expected: PluginPermissionError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PluginPermissionError, expected, file: file, line: line)
        }
    }

    private func assertAsyncPermissionFailure<T>(
        _ expected: PluginPermissionError, file: StaticString = #filePath, line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PluginPermissionError, expected, file: file, line: line)
        }
    }

    private func assertStoredValue(
        _ store: PluginStorage, pluginID: String, key: String, equals expected: PluginBridgeJSON,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await store.get(pluginID: pluginID, key: key)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while runtime.snapshot.state != .running {
            guard runtime.snapshot.lastFailure == nil, ContinuousClock.now < deadline else {
                XCTFail("Runtime did not reach running: \(String(describing: runtime.snapshot.lastFailure)).")
                throw PermissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        while try await runtime.evaluateForTesting("globalThis['\(name)'] === true") != .boolean(true) {
            guard ContinuousClock.now < deadline else {
                XCTFail("JavaScript Promise marker \(name) did not settle.")
                throw PermissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func runProbe(_ runtime: PluginRuntime) async throws {
        _ = try await runtime.evaluateForTesting("globalThis.done = false; probe(); void 0")
        try await marker(runtime, "done")
    }

    private func assertJavaScript(
        _ runtime: PluginRuntime, _ source: String, equals expected: PluginJavaScriptValue,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let actual = try await runtime.evaluateForTesting(source)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func waitForIO(_ gate: PermissionStorageIOGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.hasEntered {
            guard ContinuousClock.now < deadline else {
                gate.release()
                XCTFail("Storage did not reach the disk preparation gate.")
                throw PermissionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct PermissionStorageWorkspace {
    let configuration: PluginStorageConfiguration

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginPermissionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        configuration = .init(rootDirectoryURL: root)
    }

    func file(_ id: String) throws -> URL { try configuration.namespaceFileURL(pluginID: id) }
    func remove() { try? FileManager.default.removeItem(at: configuration.rootDirectoryURL) }
}

@MainActor
private final class PermissionRuntimeFixture {
    let permissions = PermissionManager()
    let service: PluginJSBridge
    let lifecycle: PluginLifecycleBridge
    private let factory = PermissionRuntimeFactory()

    init(store: PluginStorage) {
        let permissions = permissions
        let service = PluginJSBridge(storage: store, permissions: permissions)
        self.service = service
        let manager = ActivityManager(clock: TestActivityClock(Date(timeIntervalSinceReferenceDate: 99_000)), configuration: .immediate)
        let factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager), permissions: permissions) { package in
            let runtime = PluginRuntime(package: package, bridge: service)
            factory.runtimes.append(runtime)
            return PermissionRuntimeForwarder(runtime: runtime)
        }
    }

    func load(_ package: ValidatedPluginPackage) -> PluginRuntime {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return factory.runtimes.last!
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class PermissionRuntimeFactory {
    var runtimes: [PluginRuntime] = []
}

@MainActor
private final class PermissionRuntimeForwarder: PluginLifecycleRuntime {
    let runtime: PluginRuntime

    init(runtime: PluginRuntime) { self.runtime = runtime }
    func onStart(context: PluginExecutionContext) throws { try runtime.onStart(context: context) }
    func onStop(reason: PluginStopReason) throws { try runtime.onStop(reason: reason) }
    func teardown() { runtime.teardown() }
}

private nonisolated final class PermissionStorageIOGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var mainThread = false
    var hasEntered: Bool { lock.withLock { entered } }
    var wasOnMainThread: Bool { lock.withLock { mainThread } }

    func observe() {
        let shouldBlock = lock.withLock {
            guard !entered else { return false }
            entered = true
            mainThread = Thread.isMainThread
            return true
        }
        if shouldBlock { _ = semaphore.wait(timeout: .now() + 5) }
    }

    func release() { semaphore.signal() }
}

private nonisolated enum PermissionTestError: Error { case timedOut }
