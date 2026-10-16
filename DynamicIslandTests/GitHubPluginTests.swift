import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class GitHubPluginTests: XCTestCase {
    func testEnableRequestsEachPermissionAndDeniedNetworkDoesNotBlockSettings() async throws {
        let f = try GitHubPluginFixture()
        defer { f.shutdown() }
        XCTAssertEqual(f.package.manifest.id, "com.dynamicisland.github")
        XCTAssertEqual(f.package.manifest.version, try SemanticVersion("0.1.0"))
        XCTAssertEqual(Set(f.package.manifest.permissions), Set([.network, .localStorage, .openLinks]))
        XCTAssertEqual(Set(f.package.manifest.capabilities), Set([
            .publishActivity, .updateActivity, .endActivity, .islandNodeUI, .handleActions,
            .localStorage, .scheduler, .openLinks
        ]))
        for permission in f.package.manifest.permissions {
            XCTAssertEqual(try f.permissions.state(permission: permission, package: f.package), .requested)
        }
        try f.decide(.network, .denied)
        try f.decide(.localStorage, .granted)
        try await f.load()
        try await f.waitUntil { f.text.contains("网络未授权") }
        try f.act("repo.cli")
        try await f.waitUntil { f.tool?.presentation.subtitle?.hasPrefix("cli/cli ·") == true }
        try await f.waitForSettings(repository: "cli/cli", results: [nil, nil])
        XCTAssertEqual(f.server.requestCount, 0)
        XCTAssertEqual(try f.permissions.state(permission: .openLinks, package: f.package), .requested)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 300)
        f.assertRunning()
    }

    func testQueuedRunningAndResultUseStableBuildIdentityAndNotifyOnlyOnce() async throws {
        let f = try GitHubPluginFixture()
        defer { f.shutdown() }
        try f.grant(.network, .localStorage)
        f.server.cycle(status: "queued")
        try await f.load()
        try await f.waitForCycle(2, status: "排队中")
        let id = f.buildID(42)
        let queued = try XCTUnwrap(f.manager.activity(id: id))
        XCTAssertEqual(queued.lifecycle.policy, .progress)
        XCTAssertNil(queued.presentation.progress, "A CI stage is not a percentage.")
        let token = try XCTUnwrap(f.manager.currentSnapshot).instanceToken
        f.server.cycle(status: "in_progress")
        try f.act("refresh")
        try await f.waitForCycle(4, status: "构建中")
        XCTAssertEqual(f.manager.activity(id: id)?.presentation.title, "构建中")
        // Selecting the dashboard changes the foreground surface; the build's
        // original token remains available through a current build snapshot.
        f.manager.clearToolSelection()
        XCTAssertEqual(f.manager.currentSnapshot?.instanceToken, token)
        f.server.cycle(status: "completed", conclusion: "success")
        try f.act("refresh")
        try await f.waitForCycle(6, status: "构建成功")
        let completed = try XCTUnwrap(f.manager.currentSnapshot)
        XCTAssertEqual(completed.activity.id, id)
        XCTAssertNotEqual(completed.instanceToken, token)
        XCTAssertEqual(completed.activity.lifecycle.policy, .transient)
        XCTAssertNil(completed.activity.presentation.progress)
        try f.assertSafeLayouts(completed.activity.presentation)
        try await f.waitForSettings(repository: "actions/checkout", results: ["42.1", nil])
        try f.manager.dismiss(id: id, source: completed.activity.source)
        f.server.cycle(status: "completed", conclusion: "success")
        try f.act("refresh")
        try await f.waitForCycle(8, status: "构建成功")
        XCTAssertEqual(f.manager.activity(id: id)?.lifecycle.state, .dismissed)
        XCTAssertNotEqual(f.manager.currentSnapshot?.activity.id, id)
        XCTAssertEqual(f.server.maximumConcurrentRequests, 1)
        XCTAssertEqual(f.scheduler.snapshot.pendingCount, 1)
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 300)
        for request in f.server.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "DynamicIsland-GitHub-Plugin")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        f.assertRunning()
    }

    func testOpenUsesCommittedCachedLinksWhileFetchAndStorageAreBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = GitHubPluginStorageGate()
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root), ioObserver: { gate.observe() })
        let f = try GitHubPluginFixture(storage: storage)
        defer { gate.release(); f.shutdown() }
        try f.grant(.network, .localStorage, .openLinks)
        f.server.cycle(status: "in_progress")
        try await f.load()
        try await f.waitForCycle(2, status: "构建中")
        gate.arm()
        try f.act("repo.checkout") // same repository: a settings write only
        try await f.waitUntil { gate.hasEntered }
        f.server.cycle(id: 43, status: "in_progress", pullNumber: 8, holdRun: true)
        try f.act("refresh")
        try await f.waitUntil { f.server.heldCount == 1 }
        try f.act("open.build")
        try await f.waitUntil { f.opened.count == 1 }
        f.clock.linkInstant = f.clock.linkInstant.advanced(by: .seconds(2))
        try f.act("open.pr")
        try await f.waitUntil { f.opened.count == 2 }
        XCTAssertEqual(f.opened.map(\.absoluteString), [
            "https://github.com/actions/checkout/actions/runs/42", "https://github.com/actions/checkout/pull/7"
        ])
        XCTAssertTrue(gate.isBlocking)
        XCTAssertEqual(f.server.heldCount, 1)
        gate.release()
        f.server.releaseHeld()
        try await f.waitForCycle(4, status: "构建中")
        f.assertRunning()
    }

    func testRejectedNewPresentationCannotOpenItsUnseenRunOrPR() async throws {
        let f = try GitHubPluginFixture()
        defer { f.shutdown() }
        try f.grant(.network, .openLinks)
        f.server.cycle(status: "in_progress")
        try await f.load()
        try await f.waitForCycle(2, status: "构建中")
        XCTAssertTrue(f.text.contains("PR #7"))
        // Exercise a real Host refusal to commit a new layout. The network
        // still returns a valid newer run and PR while the old tool is visible.
        f.clock.rejectActivityWrites = true
        f.server.cycle(id: 43, status: "in_progress", pullNumber: 8)
        try f.act("refresh")
        try await f.waitUntil { f.server.requestCount == 4 && f.server.activeCount == 0 }
        try await f.flushWorker()
        XCTAssertTrue(f.text.contains("PR #7"))
        try f.act("open.build")
        try await f.waitUntil { f.opened.count == 1 }
        f.clock.linkInstant = f.clock.linkInstant.advanced(by: .seconds(2))
        try f.act("open.pr")
        try await f.waitUntil { f.opened.count == 2 }
        XCTAssertEqual(f.opened.map(\.absoluteString), [
            "https://github.com/actions/checkout/actions/runs/42", "https://github.com/actions/checkout/pull/7"
        ])
        f.assertRunning()
    }

    func testLateStorageReadCannotForgetAnAlreadyPublishedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-late-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = GitHubPluginStorageGate()
        let storage = PluginStorage(configuration: .init(rootDirectoryURL: root), ioObserver: { gate.observe() })
        let f = try GitHubPluginFixture(storage: storage)
        defer { gate.release(); f.shutdown() }
        try await storage.set(pluginID: f.id, key: "settings", value: f.settings(repository: "actions/checkout", results: [nil, nil]))
        try f.grant(.network, .localStorage)
        gate.arm()
        f.server.cycle(status: "completed", conclusion: "success")
        try await f.load()
        try await f.waitUntil { gate.hasEntered }
        try await f.waitForCycle(2, status: "构建成功")
        let result = try XCTUnwrap(f.manager.currentSnapshot)
        XCTAssertEqual(result.activity.id, f.buildID(42))
        gate.release()
        try await f.waitForSettings(repository: "actions/checkout", results: ["42.1", nil])
        try await f.flushWorker()
        try f.manager.dismiss(id: result.activity.id, source: result.activity.source)
        f.server.cycle(status: "completed", conclusion: "success")
        try f.act("refresh")
        try await f.waitForCycle(4, status: "构建成功")
        XCTAssertEqual(f.manager.activity(id: result.activity.id)?.lifecycle.state, .dismissed)
        f.assertRunning()
    }

    func testTwoHourSecondaryLimitWaitsThroughBothSchedulerSegments() async throws {
        let f = try GitHubPluginFixture()
        defer { f.shutdown() }
        try f.grant(.network)
        f.server.enqueue(.init(status: 403, headers: ["Retry-After": "7200", "X-RateLimit-Remaining": "59"], body: "{}"))
        try await f.load()
        try await f.waitUntil { f.text.contains("GitHub 限流") && f.scheduler.snapshot.pendingCount == 1 }
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 3600)
        try f.act("refresh")
        try await f.flushWorker()
        XCTAssertEqual(f.server.requestCount, 1)
        try await f.fireNextRefresh()
        XCTAssertEqual(f.server.requestCount, 1, "A one-hour scheduler chunk must not shorten a two-hour Retry-After.")
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 7200)
        try f.act("refresh")
        try await f.flushWorker()
        XCTAssertEqual(f.server.requestCount, 1)
        f.server.cycle(status: "in_progress")
        try await f.fireNextRefresh()
        try await f.waitForCycle(3, status: "构建中")
        XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 7500)
        f.assertRunning()
    }

    func testOfflineAPIFailureAndBoundedJSONErrorsBackOffWithoutLeakingBodies() async throws {
        let cases: [(GitHubPluginReply, String)] = [
            (.init(failure: URLError(.notConnectedToInternet)), "离线，稍后重试"),
            (.init(status: 503, body: "private upstream detail"), "API 请求失败"),
            (.init(body: "not JSON"), "数据超出限制"),
            (.init(body: String(repeating: "x", count: 65_537)), "数据超出限制"),
            (.init(body: "{\"workflow_runs\":[],\"noise\":[" + Array(repeating: "0", count: 4_200).joined(separator: ",") + "]}"), "数据超出限制")
        ]
        for (reply, expected) in cases {
            let f = try GitHubPluginFixture()
            defer { f.shutdown() }
            try f.grant(.network)
            f.server.enqueue(reply)
            try await f.load()
            try await f.waitUntil { f.text.contains(expected) && f.scheduler.snapshot.pendingCount == 1 }
            XCTAssertEqual(f.server.requestCount, 1)
            XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 300)
            XCTAssertFalse(f.text.contains("private upstream detail"))
            try f.act("refresh")
            try await f.flushWorker()
            XCTAssertEqual(f.server.requestCount, 1)
            f.server.enqueue(.init(status: 500, body: "{}"))
            try await f.fireNextRefresh()
            try await f.waitUntil { f.server.requestCount == 2 && f.scheduler.snapshot.pendingCount == 1 }
            XCTAssertEqual(f.scheduler.snapshot.nextDeadline, 900, "A second consecutive failure backs off to ten minutes.")
            f.assertRunning()
        }
    }

    func testDeniedStorageStillLoadsPublicDataAndUnsafeAPIURLsNeverOpen() async throws {
        let f = try GitHubPluginFixture()
        defer { f.shutdown() }
        try f.grant(.network, .openLinks)
        try f.decide(.localStorage, .denied)
        f.server.cycle(status: "in_progress", runURL: "https://github.com.evil.example/actions/checkout/actions/runs/42",
                       pullURL: "https://name:secret@github.com/actions/checkout/pull/7")
        try await f.load()
        try await f.waitForCycle(2, status: "构建中")
        try await f.waitUntil { f.text.contains("未保存") }
        try f.act("open.build")
        try await f.waitUntil { f.text.contains("暂无可打开链接") }
        try f.act("open.pr")
        try await f.flushWorker()
        XCTAssertTrue(f.opened.isEmpty)
        let stored = try await f.storage.get(pluginID: f.id, key: "settings")
        XCTAssertEqual(stored, .null)
        try f.assertSafeLayouts(try XCTUnwrap(f.tool).presentation)
        f.assertRunning()
    }

    func testRepositorySettingsAndCompletedDedupeSurviveANewHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("github-persistence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = PluginStorageConfiguration(rootDirectoryURL: root)
        let first = try GitHubPluginFixture(storage: PluginStorage(configuration: configuration))
        defer { first.shutdown() }
        try first.grant(.network, .localStorage)
        first.server.cycle(status: "in_progress")
        try await first.load()
        try await first.waitForCycle(2, status: "构建中")
        first.server.cycle(repository: "cli/cli", id: 99, status: "completed", conclusion: "failure")
        try first.act("repo.cli")
        try await first.waitForCycle(4, status: "构建失败", repository: "cli/cli")
        try await first.waitForSettings(repository: "cli/cli", results: [nil, "99.1"])
        first.shutdown()

        let second = try GitHubPluginFixture(storage: PluginStorage(configuration: configuration))
        defer { second.shutdown() }
        try second.grant(.network, .localStorage)
        // Hold any initial default-repository request until the independent
        // durable settings read has committed the saved repository selection.
        second.server.enqueue(.init(body: "{\"workflow_runs\":[]}", hold: true,
                                    path: "/repos/actions/checkout/actions/runs"))
        second.server.cycle(repository: "cli/cli", id: 99, status: "completed", conclusion: "failure")
        try await second.load()
        try await second.waitUntil { second.tool?.presentation.subtitle?.hasPrefix("cli/cli ·") == true }
        try await second.waitUntil { second.server.requestCount >= 1 }
        second.server.releaseHeld()
        try await second.waitUntil { second.text.contains("PR #7") && second.tool?.presentation.subtitle == "cli/cli · 构建失败" }
        XCTAssertNil(second.manager.activity(id: second.buildID(99, repository: "cli/cli")))
        XCTAssertNil(first.manager.activity(id: first.buildID(42)))
        second.assertRunning()
    }

    func testLivePublicGitHubAPIThroughOfficialPluginWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["DYNAMIC_ISLAND_GITHUB_LIVE"] == "1" else {
            throw XCTSkip("Set DYNAMIC_ISLAND_GITHUB_LIVE=1 to verify the anonymous public GitHub API.")
        }
        let f = try GitHubPluginFixture(live: true)
        defer { f.shutdown() }
        try f.grant(.network, .localStorage)
        try await f.load()
        try await f.waitUntil(timeout: 30) {
            f.scheduler.snapshot.pendingCount == 1 && !f.text.contains("正在读取")
        }
        guard !(f.text.contains("限流") || f.text.contains("失败") && f.text.contains("API") ||
                f.text.contains("离线") || f.text.contains("访问受限") || f.text.contains("数据超出限制") || f.text.contains("网络未授权")),
              f.text.contains("PR #") || f.text.contains("暂无打开的 PR") else {
            XCTFail("Live public API verification failed: \(f.text)")
            throw GitHubPluginTestError.liveRequestFailed
        }
        // This read-only projection records the minimal already fetched public
        // fields for audit; it sends no additional API request or command.
        let projection = try await XCTUnwrap(f.runtimes.last).evaluateForTesting("""
            JSON.stringify({repository, run: run && {id:run.id, attempt:run.attempt,
                status:run.status, conclusion:run.conclusion, url:run.url},
                pr:pull && {number:pull.number, url:pull.url}})
            """)
        guard case .string(let json) = projection,
              let data = json.data(using: .utf8),
              var result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("The live plugin did not expose a valid bounded public result.")
            throw GitHubPluginTestError.liveRequestFailed
        }
        guard result["run"] is [String: Any] else {
            XCTFail("The public reference repository should have at least one workflow run.")
            throw GitHubPluginTestError.liveRequestFailed
        }
        result["checkedAt"] = ISO8601DateFormatter().string(from: Date())
        result["transport"] = "PluginNetworkBroker default URLSession; no URLProtocol fixture"
        result["apiVersion"] = "2026-03-10"
        result["result"] = "passed"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t36-github-live-20261017")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        let attachment = XCTAttachment(contentsOfFile: destination)
        attachment.name = "T36 anonymous public GitHub API evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        f.assertRunning()
    }
}

@MainActor
private final class GitHubPluginFixture {
    let id = "com.dynamicisland.github"
    let package: ValidatedPluginPackage
    let clock = GitHubPluginClock()
    let storage: PluginStorage
    let permissions = PermissionManager()
    let server = GitHubPluginServer()
    let live: Bool
    let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 42_000))
    lazy var manager = ActivityManager(clock: activityClock, configuration: .immediate)
    lazy var router = ActionRouter(manager: manager)
    lazy var scheduler = PluginScheduler(policy: .background, clock: { [clock] in clock.schedulerNow }, automaticScheduling: false)
    var opened: [URL] = []
    var runtimes: [PluginRuntime] = []
    lazy var links = PluginLinkBroker(now: { [clock] in clock.linkInstant }, opener: { [unowned self] url in
        opened.append(url)
        return true
    })
    lazy var bridge = PluginJSBridge(storage: storage, permissions: permissions, network: networkBroker(), links: links,
                                    scheduler: scheduler, activityRateClock: { [clock] in
        clock.activityWrites += 1
        return clock.rejectActivityWrites ? .nan : TimeInterval(clock.activityWrites)
    })
    lazy var lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: router, permissions: permissions,
        runtimeFactory: { [unowned self] package in
            let runtime = PluginRuntime(package: package, bridge: bridge)
            runtimes.append(runtime)
            return runtime
        })

    init(storage: PluginStorage = PluginStorage(), live: Bool = false) throws {
        self.storage = storage
        self.live = live
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples/github")
        package = try PluginValidator().validateExpandedPackage(at: root,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: root.deletingLastPathComponent()))
        permissions.request(package: package)
        if !live { GitHubPluginURLProtocol.install(server) }
    }

    var tool: IslandActivity? { manager.activity(id: PluginJSBridge.activityID(pluginID: id, localID: "dashboard")) }
    var text: String {
        guard let node = tool?.presentation.expanded else { return "" }
        return Self.texts(node).joined(separator: "\n")
    }

    func networkBroker() -> PluginNetworkBroker {
        if live { return PluginNetworkBroker() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubPluginURLProtocol.self]
        return PluginNetworkBroker(configuration: configuration, resolver: { _ in ["8.8.8.8"] })
    }

    func decide(_ permission: PluginPermission, _ decision: PluginPermissionDecision) throws {
        let review = try permissions.snapshot(package: package).review
        try permissions.applyHostDecision(decision: decision, review: review, permission: permission)
    }

    func grant(_ values: PluginPermission...) throws {
        for value in values { try decide(value, .granted) }
    }

    func load() async throws {
        lifecycle.pluginDidLoad(package, isEnabled: true)
        try await waitUntil { self.tool != nil }
    }

    func act(_ actionID: String, file: StaticString = #filePath, line: UInt = #line) throws {
        if let current = manager.currentSnapshot, current.activity.lifecycle.policy == .transient {
            try manager.dismiss(id: current.activity.id, source: current.activity.source)
        }
        let snapshot = try XCTUnwrap(manager.toolSnapshots.first { $0.activity.source.identifier == id }, file: file, line: line)
        XCTAssertTrue(manager.selectTool(snapshot), file: file, line: line)
        XCTAssertEqual(router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none)), .handled, file: file, line: line)
    }

    func buildID(_ number: Int, repository: String = "actions/checkout") -> String {
        PluginJSBridge.activityID(pluginID: id, localID: "build.\(repository == "cli/cli" ? "cli" : "checkout").\(number).1")
    }

    func waitForCycle(_ requests: Int, status: String, repository: String = "actions/checkout",
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil(file: file, line: line) {
            self.server.requestCount == requests && self.server.activeCount == 0 &&
                self.tool?.presentation.subtitle == "\(repository) · \(status)" && !self.text.contains("正在读取")
        }
        try await flushWorker()
    }

    func waitUntil(timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
                   _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeout * 1_000)))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Official GitHub plugin public state did not settle: \(text)", file: file, line: line)
                throw GitHubPluginTestError.unsettled
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func flushWorker() async throws {
        try await Task.sleep(for: .milliseconds(30))
        _ = try await XCTUnwrap(runtimes.last).evaluateForTesting("void 0")
    }

    func fireNextRefresh() async throws {
        let deadline = try XCTUnwrap(scheduler.snapshot.nextDeadline)
        clock.schedulerNow = deadline
        scheduler.processDue()
        try await waitUntil { self.scheduler.snapshot.pendingCount == 1 }
        try await flushWorker()
    }

    func settings(repository: String, results: [String?]) -> PluginBridgeJSON {
        .object(["schemaVersion": .number(1), "repository": .string(repository),
                 "notifiedResults": .array(results.map { $0.map(PluginBridgeJSON.string) ?? .null })])
    }

    func waitForSettings(repository: String, results: [String?], file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        let expected = settings(repository: repository, results: results)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await storage.get(pluginID: id, key: "settings") != expected {
            guard ContinuousClock.now < deadline else {
                XCTFail("Official GitHub settings did not become durable.", file: file, line: line)
                throw GitHubPluginTestError.unsettled
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func assertSafeLayouts(_ presentation: ActivityPresentation, file: StaticString = #filePath, line: UInt = #line) throws {
        let compact = try XCTUnwrap(presentation.compact, file: file, line: line)
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(compact, for: .compact), file: file, line: line)
        guard case .hStack(let wings) = compact, wings.children.count == 3,
              case .icon = wings.children[0], case .spacer = wings.children[1], case .text(let trailing) = wings.children[2] else {
            return XCTFail("Compact must keep separate icon and short-text wings.", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(trailing.content.count, 2, file: file, line: line)
        let expanded = try XCTUnwrap(presentation.expanded, file: file, line: line)
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(expanded, for: .expanded), file: file, line: line)
        if presentation.effectiveRole == .tool, case .vStack(let rows) = expanded {
            XCTAssertEqual(rows.children.count, 5, file: file, line: line)
        }
    }

    func assertRunning(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lifecycle.snapshot(id: id)?.state, .running, file: file, line: line)
        XCTAssertNil(lifecycle.snapshot(id: id)?.lastFailure, file: file, line: line)
        XCTAssertTrue(runtimes.allSatisfy { $0.snapshot.lastFailure == nil }, file: file, line: line)
        XCTAssertEqual(server.unexpectedRequests, 0, file: file, line: line)
    }

    func shutdown() {
        lifecycle.shutdown()
        scheduler.shutdown()
        permissions.revokeAll()
        if !live { GitHubPluginURLProtocol.uninstall(server) }
    }

    static func texts(_ node: IslandNode) -> [String] {
        switch node {
        case .text(let value): return [value.content]
        case .hStack(let value), .vStack(let value), .zStack(let value): return value.children.flatMap(texts)
        case .button(let value): return texts(value.label)
        default: return []
        }
    }
}

@MainActor
private final class GitHubPluginClock {
    var schedulerNow: TimeInterval = 0
    var activityWrites = 0
    var rejectActivityWrites = false
    var linkInstant = ContinuousClock.now
}

private enum GitHubPluginTestError: Error { case unsettled, liveRequestFailed }

private nonisolated struct GitHubPluginReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = ""
    var failure: URLError?
    var hold = false
    var path: String?
}

private nonisolated final class GitHubPluginServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [GitHubPluginReply] = []
    private var seen: [URLRequest] = []
    private var held: [(GitHubPluginURLProtocol, GitHubPluginReply)] = []
    private var active: Set<ObjectIdentifier> = []
    private var maximum = 0
    private var unexpected = 0
    var requests: [URLRequest] { lock.withLock { seen } }
    var requestCount: Int { lock.withLock { seen.count } }
    var heldCount: Int { lock.withLock { held.count } }
    var activeCount: Int { lock.withLock { active.count } }
    var maximumConcurrentRequests: Int { lock.withLock { maximum } }
    var unexpectedRequests: Int { lock.withLock { unexpected } }

    func enqueue(_ reply: GitHubPluginReply) { lock.withLock { replies.append(reply) } }

    func cycle(repository: String = "actions/checkout", id: Int = 42, status: String,
               conclusion: String? = nil, pullNumber: Int = 7, holdRun: Bool = false,
               runURL: String? = nil, pullURL: String? = nil) {
        let run: [String: Any] = ["id": id, "run_attempt": 1, "status": status,
            "conclusion": conclusion.map { $0 as Any } ?? NSNull(), "name": "CI",
            "html_url": runURL ?? "https://github.com/\(repository)/actions/runs/\(id)"]
        let pulls: [[String: Any]] = [["number": pullNumber, "title": "Improve public workflow",
            "html_url": pullURL ?? "https://github.com/\(repository)/pull/\(pullNumber)"]]
        let runData = try! JSONSerialization.data(withJSONObject: ["workflow_runs": [run]])
        let pullData = try! JSONSerialization.data(withJSONObject: pulls)
        enqueue(.init(body: String(decoding: runData, as: UTF8.self), hold: holdRun,
                      path: "/repos/\(repository)/actions/runs"))
        enqueue(.init(body: String(decoding: pullData, as: UTF8.self), path: "/repos/\(repository)/pulls"))
    }

    func start(_ instance: GitHubPluginURLProtocol) {
        let reply: GitHubPluginReply = lock.withLock {
            seen.append(instance.request)
            active.insert(ObjectIdentifier(instance))
            maximum = max(maximum, active.count)
            guard let index = replies.firstIndex(where: { $0.path == nil || $0.path == instance.request.url?.path }) else {
                unexpected += 1
                return .init(failure: URLError(.badServerResponse))
            }
            return replies.remove(at: index)
        }
        if reply.hold { lock.withLock { held.append((instance, reply)) } }
        else { respond(instance, reply: reply) }
    }

    func releaseHeld() {
        let values = lock.withLock { let values = held; held.removeAll(); return values }
        for (instance, reply) in values { respond(instance, reply: reply) }
    }

    func stop(_ instance: GitHubPluginURLProtocol) {
        _ = lock.withLock { active.remove(ObjectIdentifier(instance)) }
    }

    private func respond(_ instance: GitHubPluginURLProtocol, reply: GitHubPluginReply) {
        guard lock.withLock({ active.remove(ObjectIdentifier(instance)) != nil }), let client = instance.client else { return }
        if let failure = reply.failure { client.urlProtocol(instance, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: instance.request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(instance, didLoad: Data(reply.body.utf8))
        client.urlProtocolDidFinishLoading(instance)
    }
}

private nonisolated final class GitHubPluginURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var installed: GitHubPluginServer?
    private var server: GitHubPluginServer?
    static func install(_ value: GitHubPluginServer) { lock.withLock { installed = value } }
    static func uninstall(_ value: GitHubPluginServer) { lock.withLock { if installed === value { installed = nil } } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let selected = Self.lock.withLock({ Self.installed }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        server = selected
        selected.start(self)
    }
    override func stopLoading() { server?.stop(self) }
}

private nonisolated final class GitHubPluginStorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var entered = false
    private var released = false
    var hasEntered: Bool { lock.withLock { entered } }
    var isBlocking: Bool { lock.withLock { entered && !released } }
    func arm() { lock.withLock { armed = true } }
    func observe() {
        let block = lock.withLock {
            guard armed, !entered else { return false }
            entered = true
            return true
        }
        if block { _ = semaphore.wait(timeout: .now() + 12) }
    }
    func release() { lock.withLock { released = true }; semaphore.signal() }
}
