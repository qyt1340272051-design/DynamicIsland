import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import DynamicIsland

@MainActor
final class PluginActivityBridgeTests: XCTestCase {
    func testPublishMapsDefaultsAndHostIdentityFromValidatedPackage() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let response = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
            "id": "build", "presentation": ["title": "GitHub 构建", "progress": 0]
        ])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual((response["value"] as? [String: Any])?["id"] as? String, "build")
        let activity = try XCTUnwrap(fixture.activity("build"))
        XCTAssertEqual(activity.source, context.source)
        XCTAssertEqual(activity.id, "plugin:com.example.alpha:build")
        XCTAssertEqual(activity.priority, .normal)
        XCTAssertEqual(activity.lifecycle.policy, .transient)
        XCTAssertEqual(activity.createdAt, fixture.activityClock.now())
        XCTAssertNil(activity.expiresAt)
        XCTAssertTrue(activity.actions.isEmpty)
        XCTAssertNil(activity.presentation.minimal)
        XCTAssertNil(activity.presentation.compact)
        XCTAssertNil(activity.presentation.expanded)
    }

    func testPriorityAndLifecycleRequestsUseHostDowngradePolicy() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let priorities: [(String, ActivityPriority)] = [
            ("background", .background), ("normal", .normal), ("important", .normal), ("critical", .normal)
        ]
        for (index, requestPriority) in priorities.enumerated() {
            let response = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
                "id": "priority\(index)", "priority": requestPriority.0,
                "presentation": ["title": "Priority \(index)"]
            ])
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual(fixture.activity("priority\(index)")?.priority, requestPriority.1)
        }
        let policies: [(String, ActivityLifecycle.Policy)] = [
            ("transient", .transient), ("persistent", .persistent), ("progress", .progress), ("critical", .transient)
        ]
        for (index, policy) in policies.enumerated() {
            let response = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
                "id": "policy\(index)", "lifecycle": ["policy": policy.0],
                "presentation": ["title": "Policy \(index)"]
            ])
            XCTAssertEqual(response["ok"] as? Bool, true)
            XCTAssertEqual(fixture.activity("policy\(index)")?.lifecycle.policy, policy.1)
            XCTAssertTrue(fixture.activity("policy\(index)")?.lifecycle.policy.isInterruptible == true)
        }
    }

    func testUpdatePatchesTopLevelFieldsReplacesPresentationAndPreservesInstance() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: [
            "id": "build", "priority": "background", "lifecycle": ["policy": "progress"],
            "presentation": ["title": "开始构建", "subtitle": "main", "symbolName": "hammer.fill", "progress": 0],
            "actions": [["id": "open", "title": "查看构建"]]
        ])
        let original = try XCTUnwrap(fixture.activity("build"))
        let token = try XCTUnwrap(fixture.manager.currentSnapshot?.instanceToken)
        let response = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "presentation": ["title": "构建进行中", "progress": 0.5]
        ])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual((response["value"] as? [String: Any])?["id"] as? String, "build")
        let updated = try XCTUnwrap(fixture.activity("build"))
        XCTAssertEqual(updated.priority, .background)
        XCTAssertEqual(updated.actions, original.actions)
        XCTAssertEqual(updated.lifecycle, original.lifecycle)
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, token)
        XCTAssertEqual(updated.presentation, .init(title: "构建进行中", progress: 0.5))
        XCTAssertNil(updated.presentation.subtitle)
        XCTAssertNil(updated.presentation.symbolName)

        let clearActions = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "priority": "important", "actions": []
        ])
        XCTAssertEqual(clearActions["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity("build")?.priority, .normal)
        XCTAssertTrue(fixture.activity("build")?.actions.isEmpty == true)
        XCTAssertEqual(fixture.activity("build")?.presentation, updated.presentation)
    }

    func testUpdatePreservesDismissedStateAndRejectsChangedPolicyAtomically() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: [
            "id": "build", "lifecycle": ["policy": "persistent"], "presentation": ["title": "Original"]
        ])
        try fixture.manager.dismiss(id: fixture.id("build"), source: context.source)
        let before = try XCTUnwrap(fixture.activity("build"))
        XCTAssertEqual(before.lifecycle.state, .dismissed)
        let invalid = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "lifecycle": ["policy": "progress"],
            "presentation": ["title": "Must not commit"], "priority": "background"
        ])
        XCTAssertEqual(errorCode(invalid), "invalidArguments")
        XCTAssertEqual(fixture.activity("build"), before)
        let valid = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "lifecycle": ["policy": "persistent"], "presentation": ["title": "Still dismissed"]
        ])
        XCTAssertEqual(valid["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity("build")?.lifecycle.state, .dismissed)
        XCTAssertNil(fixture.manager.current)
    }

    func testUpdateNormalizesCriticalPolicyBeforeCheckingImmutablePolicy() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: [
            "id": "build", "presentation": ["title": "Original"]
        ])
        let response = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "lifecycle": ["policy": "critical"], "priority": "critical"
        ])
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity("build")?.lifecycle.policy, .transient)
        XCTAssertEqual(fixture.activity("build")?.priority, .normal)
    }

    func testPublishAndUpdateHaveIndependentCapabilitiesAndRepublishCompatibility() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let publishOnly = try package(capabilities: [.publishActivity])
        let publishContext = try fixture.load(publishOnly)
        try await publish(fixture, package: publishOnly, context: publishContext, params: [
            "id": "build", "presentation": ["title": "Original"]
        ])
        let deniedUpdate = try await request(fixture, package: publishOnly, context: publishContext, method: "activity.update", params: [
            "id": "build", "presentation": ["title": "Denied"]
        ])
        XCTAssertEqual(errorCode(deniedUpdate), "capabilityRequired")
        try await publish(fixture, package: publishOnly, context: publishContext, params: [
            "id": "build", "presentation": ["title": "Republished"]
        ])
        XCTAssertEqual(fixture.activity("build")?.presentation.title, "Republished")

        let updateOnly = try package(id: "com.example.beta", capabilities: [.updateActivity])
        let updateContext = try fixture.load(updateOnly)
        let deniedPublish = try await request(fixture, package: updateOnly, context: updateContext, method: "activity.publish", params: [
            "id": "build", "presentation": ["title": "Denied"]
        ])
        XCTAssertEqual(errorCode(deniedPublish), "capabilityRequired")
        let missing = try await request(fixture, package: updateOnly, context: updateContext, method: "activity.update", params: [
            "id": "build", "presentation": ["title": "Missing"]
        ])
        XCTAssertEqual(errorCode(missing), "activityNotFound")
        XCTAssertNil(fixture.activity("build", pluginID: updateOnly.manifest.id))
    }

    func testActionsAreDataOnlyBoundedUniqueAndRequireCapability() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let actions = (0..<8).map { ["id": "open\($0)", "title": "操作 \($0)"] }
        try await publish(fixture, package: package, context: context, params: [
            "id": "build", "presentation": ["title": "Actions"], "actions": actions
        ])
        XCTAssertEqual(fixture.activity("build")?.actions, actions.map { .init(id: $0["id"]!, title: $0["title"]!) })
        let tooMany = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "actions": actions + [["id": "overflow", "title": "Overflow"]]
        ])
        XCTAssertEqual(errorCode(tooMany), "quotaExceeded")
        let duplicates = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "actions": [["id": "same", "title": "First"], ["id": "same", "title": "Second"]]
        ])
        XCTAssertEqual(errorCode(duplicates), "invalidArguments")
        XCTAssertEqual(fixture.activity("build")?.actions.count, 8)
        let noActions = try self.package(id: "com.example.beta", capabilities: [.publishActivity, .updateActivity])
        let beta = try fixture.load(noActions)
        let denied = try await request(fixture, package: noActions, context: beta, method: "activity.publish", params: [
            "id": "build", "presentation": ["title": "Denied"], "actions": [["id": "open", "title": "Open"]]
        ])
        XCTAssertEqual(errorCode(denied), "capabilityRequired")
        XCTAssertNil(fixture.activity("build", pluginID: noActions.manifest.id))
        try await publish(fixture, package: noActions, context: beta, params: [
            "id": "build", "presentation": ["title": "No callbacks"], "actions": []
        ])
    }

    func testMalformedActivityFieldsAndUnsafeHostFieldsHaveNoSideEffects() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: ["id": "build", "presentation": ["title": "Original"]])
        let original = fixture.activity("build")
        let invalidValues: [[String: Any]] = [
            ["id": "build"],
            ["id": "build", "presentation": NSNull()],
            ["id": "build", "presentation": ["title": 2]],
            ["id": "build", "presentation": ["title": " \n"]],
            ["id": "build", "presentation": ["title": "Bad", "progress": -0.1]],
            ["id": "build", "presentation": ["title": "Bad", "progress": 1.1]],
            ["id": "build", "presentation": ["title": "Bad", "progress": true]],
            ["id": "build", "presentation": ["title": "Bad", "compact": ["type": "text", "text": "tree"]]],
            ["id": "build", "presentation": ["title": "Bad", "showsCompact": false]],
            ["id": "build", "priority": 3],
            ["id": "build", "priority": "urgent"],
            ["id": "build", "lifecycle": "persistent"],
            ["id": "build", "lifecycle": ["policy": "unknown"]],
            ["id": "build", "lifecycle": ["policy": "transient", "state": "presented"]],
            ["id": "build", "actions": "click"],
            ["id": "build", "actions": [["id": "open", "title": " \n"]]],
            ["id": "build", "actions": [["id": "open", "title": "Open", "handler": "evil"]]],
            ["id": "build", "actions": [["id": "open/path", "title": "Open"]]],
            ["id": "build", "source": ["kind": "builtIn", "identifier": "battery"]],
            ["id": "build", "state": "presented"],
            ["id": "build", "createdAt": 0],
            ["id": "build", "expiresAt": 9_999_999_999],
            ["id": "plugin:com.example.beta:build", "presentation": ["title": "Forgery"]]
        ]
        for params in invalidValues {
            let response = try await request(fixture, package: package, context: context, method: "activity.update", params: params)
            XCTAssertEqual(errorCode(response), "invalidArguments", "Unexpected response for \(params)")
            XCTAssertEqual(fixture.activity("build"), original)
            XCTAssertEqual(fixture.manager.diagnostics.activityCount, 1)
        }
        for field in ["source", "state", "createdAt", "expiresAt"] {
            let response = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
                "id": "attack", "presentation": ["title": "Attack"], field: 0
            ])
            XCTAssertEqual(errorCode(response), "invalidArguments")
            XCTAssertNil(fixture.activity("attack"))
        }
    }

    func testByteBoundariesAreAcceptedAndOversizedFieldsRejectedAtomically() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        let maximumID = String(repeating: "i", count: 80)
        let maximumTitle = String(repeating: "界", count: 85) + "x"
        XCTAssertEqual(maximumTitle.utf8.count, 256)
        let actionTitle = String(repeating: "界", count: 42) + "xx"
        XCTAssertEqual(actionTitle.utf8.count, 128)
        try await publish(fixture, package: package, context: context, params: [
            "id": maximumID,
            "presentation": ["title": maximumTitle, "subtitle": String(repeating: "s", count: 256),
                             "symbolName": String(repeating: "s", count: 128), "progress": 1],
            "actions": [["id": String(repeating: "a", count: 80), "title": actionTitle]]
        ])
        let original = fixture.activity(maximumID)
        let tooLarge: [[String: Any]] = [
            ["id": String(repeating: "i", count: 81), "presentation": ["title": "Oversized ID"]],
            ["id": maximumID, "presentation": ["title": maximumTitle + "x"]],
            ["id": maximumID, "presentation": ["title": "Title", "subtitle": String(repeating: "s", count: 257)]],
            ["id": maximumID, "presentation": ["title": "Title", "symbolName": String(repeating: "s", count: 129)]],
            ["id": maximumID, "actions": [["id": String(repeating: "a", count: 81), "title": "Title"]]],
            ["id": maximumID, "actions": [["id": "a", "title": actionTitle + "x"]]]
        ]
        for params in tooLarge {
            let response = try await request(fixture, package: package, context: context, method: "activity.update", params: params)
            XCTAssertEqual(errorCode(response), "quotaExceeded")
            XCTAssertEqual(fixture.activity(maximumID), original)
        }
    }

    func testHostRejectsDuplicateKeysAndNonfiniteNumbersInUpdateJSON() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: ["id": "build", "presentation": ["title": "Original"]])
        let original = fixture.activity("build")
        for params in [
            #"{"id":"build","priority":"normal","priority":"critical"}"#,
            #"{"id":"build","lifecycle":{"policy":"transient","policy":"critical"}}"#,
            #"{"id":"build","actions":[{"id":"open","title":"Open","title":"Changed"}]}"#,
            #"{"id":"build","presentation":{"title":"Bad","progress":1e400}}"#
        ] {
            let response = try decode(await fixture.service.handle(
                "{\"apiVersion\":\"1.0.0\",\"method\":\"activity.update\",\"params\":\(params)}",
                package: package, context: context
            ))
            XCTAssertEqual(errorCode(response), "invalidArguments")
            XCTAssertEqual(fixture.activity("build"), original)
        }
    }

    func testPublishAndUpdateShareRateBudgetRejectWithoutMutationAndRefill() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: ["id": "build", "presentation": ["title": "0"]])
        for index in 1..<20 {
            let response = try await request(fixture, package: package, context: context,
                                       method: index.isMultiple(of: 2) ? "activity.publish" : "activity.update", params: [
                "id": "build", "presentation": ["title": "\(index)"]
            ])
            XCTAssertEqual(response["ok"] as? Bool, true)
        }
        let original = fixture.activity("build")
        for method in ["activity.publish", "activity.update"] {
            let denied = try await request(fixture, package: package, context: context, method: method, params: [
                "id": "build", "presentation": ["title": "Must not commit"]
            ])
            XCTAssertEqual(errorCode(denied), "rateLimited")
            XCTAssertEqual(fixture.activity("build"), original)
        }
        fixture.rateClock.now += 0.1
        let recovered = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build", "presentation": ["title": "Recovered"]
        ])
        XCTAssertEqual(recovered["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity("build")?.presentation.title, "Recovered")
        let exhausted = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "build", "priority": "normal"])
        XCTAssertEqual(errorCode(exhausted), "rateLimited")
    }

    func testRejectedRequestsDoNotConsumeWriteBudget() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        for _ in 0..<30 {
            let missing = try await request(fixture, package: package, context: context, method: "activity.update", params: [
                "id": "missing", "presentation": ["title": "Missing"]
            ])
            XCTAssertEqual(errorCode(missing), "activityNotFound")
            let malformed = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
                "id": "bad", "presentation": ["title": false]
            ])
            XCTAssertEqual(errorCode(malformed), "invalidArguments")
        }
        try await publish(fixture, package: package, context: context, params: ["id": "build", "presentation": ["title": "Original"]])
        for _ in 0..<30 {
            let policyChange = try await request(fixture, package: package, context: context, method: "activity.update", params: [
                "id": "build", "lifecycle": ["policy": "persistent"]
            ])
            XCTAssertEqual(errorCode(policyChange), "invalidArguments")
        }
        for index in 1..<20 {
            let response = try await request(fixture, package: package, context: context, method: "activity.update", params: [
                "id": "build", "presentation": ["title": "\(index)"]
            ])
            XCTAssertEqual(response["ok"] as? Bool, true)
        }
        let exhausted = try await request(fixture, package: package, context: context, method: "activity.update", params: ["id": "build", "priority": "normal"])
        XCTAssertEqual(errorCode(exhausted), "rateLimited")
    }

    func testCoreQuotaFailureKeepsWriteAllowanceAndExpiredEventsCannotBeUpdated() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        for index in 0..<16 {
            try await publish(fixture, package: package, context: context, params: [
                "id": "build\(index)", "presentation": ["title": "Build \(index)"]
            ])
        }
        for _ in 0..<30 {
            let rejected = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
                "id": "excess", "presentation": ["title": "Cannot commit"]
            ])
            XCTAssertEqual(errorCode(rejected), "quotaExceeded")
        }
        for index in 0..<4 {
            let updated = try await request(fixture, package: package, context: context, method: "activity.update", params: [
                "id": "build0", "presentation": ["title": "Accepted \(index)"]
            ])
            XCTAssertEqual(updated["ok"] as? Bool, true)
        }
        let exhausted = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build0", "priority": "normal"
        ])
        XCTAssertEqual(errorCode(exhausted), "rateLimited")

        // Deadline reconciliation precedes lookup; update cannot recreate an
        // event whose data lifetime has ended, even when allowance returns.
        fixture.activityClock.advance(by: 60)
        fixture.rateClock.now += 2
        let expired = try await request(fixture, package: package, context: context, method: "activity.update", params: [
            "id": "build0", "presentation": ["title": "Must not reopen"]
        ])
        XCTAssertEqual(errorCode(expired), "activityNotFound")
        XCTAssertNil(fixture.activity("build0"))
        try await publish(fixture, package: package, context: context, params: [
            "id": "afterexpiry", "presentation": ["title": "New event"]
        ])
        XCTAssertEqual(fixture.manager.diagnostics.activityCount, 1)
    }

    func testEndBypassesRateLimitAndDoesNotResetBudgetForNewIDsOrReload() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let context = try fixture.load(package)
        try await publish(fixture, package: package, context: context, params: ["id": "build", "presentation": ["title": "0"]])
        for index in 1..<20 {
            let updated = try await request(fixture, package: package, context: context, method: "activity.update", params: [
                "id": "build", "presentation": ["title": "\(index)"]
            ])
            XCTAssertEqual(updated["ok"] as? Bool, true)
        }
        let ended = try await request(fixture, package: package, context: context, method: "activity.end", params: ["id": "build"])
        XCTAssertEqual(ended["ok"] as? Bool, true)
        XCTAssertNil(fixture.activity("build"))
        let newID = try await request(fixture, package: package, context: context, method: "activity.publish", params: [
            "id": "different", "presentation": ["title": "Denied"]
        ])
        XCTAssertEqual(errorCode(newID), "rateLimited")
        let replacement = try fixture.load(package)
        let reloaded = try await request(fixture, package: package, context: replacement, method: "activity.publish", params: [
            "id": "afterreload", "presentation": ["title": "Denied"]
        ])
        XCTAssertEqual(errorCode(reloaded), "rateLimited")
        fixture.rateClock.now += 2
        try await publish(fixture, package: package, context: replacement, params: ["id": "afterreload", "presentation": ["title": "Recovered"]])
    }

    func testRateBudgetAndSameLocalIDAreSeparatedByTrustedPluginIdentity() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let alphaPackage = try package()
        let alpha = try fixture.load(alphaPackage)
        try await publish(fixture, package: alphaPackage, context: alpha, params: ["id": "same", "presentation": ["title": "Alpha"]])
        for index in 1..<20 {
            let response = try await request(fixture, package: alphaPackage, context: alpha, method: "activity.update", params: [
                "id": "same", "presentation": ["title": "Alpha \(index)"]
            ])
            XCTAssertEqual(response["ok"] as? Bool, true)
        }
        let betaPackage = try package(id: "com.example.beta")
        let beta = try fixture.load(betaPackage)
        try await publish(fixture, package: betaPackage, context: beta, params: ["id": "same", "presentation": ["title": "Beta"]])
        let updated = try await request(fixture, package: betaPackage, context: beta, method: "activity.update", params: [
            "id": "same", "presentation": ["title": "Beta updated"]
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true)
        XCTAssertEqual(fixture.activity("same")?.presentation.title, "Alpha 19")
        XCTAssertEqual(fixture.activity("same", pluginID: betaPackage.manifest.id)?.presentation.title, "Beta updated")
        let forgedContext = try await request(fixture, package: alphaPackage, context: beta, method: "activity.update", params: [
            "id": "same", "presentation": ["title": "Forged identity"]
        ])
        XCTAssertEqual(errorCode(forgedContext), "coreRejected")
        XCTAssertEqual(fixture.activity("same")?.presentation.title, "Alpha 19")
    }

    func testDisabledAndReplacedExecutionCannotUpdateActivitiesOrSpendNewSessionBudget() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let package = try package()
        let old = try fixture.load(package)
        try await publish(fixture, package: package, context: old, params: ["id": "build", "presentation": ["title": "Original"]])
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)
        let disabled = try await request(fixture, package: package, context: old, method: "activity.update", params: [
            "id": "build", "presentation": ["title": "Late disabled"]
        ])
        XCTAssertEqual(errorCode(disabled), "inactiveExecution")
        XCTAssertNil(fixture.activity("build"))
        fixture.lifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: true)
        let replacement = try XCTUnwrap(fixture.contexts.last)
        try await publish(fixture, package: package, context: replacement, params: ["id": "build", "presentation": ["title": "Replacement"]])
        let before = fixture.activity("build")
        for _ in 0..<30 {
            let late = try await request(fixture, package: package, context: old, method: "activity.update", params: [
                "id": "build", "presentation": ["title": "Late replacement"]
            ])
            XCTAssertEqual(errorCode(late), "inactiveExecution")
            XCTAssertEqual(fixture.activity("build"), before)
        }
        for index in 2..<20 {
            let valid = try await request(fixture, package: package, context: replacement, method: "activity.update", params: [
                "id": "build", "presentation": ["title": "\(index)"]
            ])
            XCTAssertEqual(valid["ok"] as? Bool, true)
        }
    }

    func testRealJavaScriptGitHubMockProgressUpdatesRenderSameHostInstance() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let exampleSource = repository.appendingPathComponent("docs/plugin-system/examples/github-mock", isDirectory: true)
        let exampleContainer = FileManager.default.temporaryDirectory.appendingPathComponent("t24-github-mock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exampleContainer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exampleContainer) }
        let exampleRoot = exampleContainer.appendingPathComponent("github-mock", isDirectory: true)
        try FileManager.default.copyItem(at: exampleSource, to: exampleRoot)
        let example = try PluginValidator().validateExpandedPackage(
            at: exampleRoot,
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: exampleContainer)
        )
        XCTAssertEqual(example.manifest.id, "com.example.github-mock")
        XCTAssertTrue(example.manifest.permissions.isEmpty)
        XCTAssertEqual(Set(example.manifest.capabilities), Set([.publishActivity, .updateActivity, .endActivity]))
        let runtime = try fixture.loadJavaScript(example)
        try await logMarker(fixture, pluginID: example.manifest.id, message: "mock.ready")
        let start = try XCTUnwrap(fixture.activity("build", pluginID: example.manifest.id))
        let token = try XCTUnwrap(fixture.manager.currentSnapshot?.instanceToken)
        XCTAssertEqual(start.priority, .normal)
        XCTAssertEqual(start.lifecycle.policy, .progress)
        XCTAssertEqual(start.presentation.progress, 0.1)
        let view = NSHostingView(rootView: ActivityBridgeRenderedView(manager: fixture.manager))
        view.frame = CGRect(x: 0, y: 0, width: 470, height: 150)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        let startPixels = try await render(view)

        _ = try await runtime.evaluateForTesting("mockBuildProgress(0.5); void 0")
        try await logMarker(fixture, pluginID: example.manifest.id, message: "mock.progress:0.5")
        let progress = try XCTUnwrap(fixture.activity("build", pluginID: example.manifest.id))
        XCTAssertEqual(progress.presentation.progress, 0.5)
        XCTAssertEqual(progress.createdAt, start.createdAt)
        XCTAssertEqual(progress.lifecycle, start.lifecycle)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, token)
        let progressPixels = try await render(view)
        XCTAssertNotEqual(progressPixels, startPixels)

        _ = try await runtime.evaluateForTesting("mockBuildProgress(1); void 0")
        try await logMarker(fixture, pluginID: example.manifest.id, message: "mock.progress:1")
        let completion = try XCTUnwrap(fixture.activity("build", pluginID: example.manifest.id))
        XCTAssertEqual(completion.presentation.title, "GitHub Mock 构建完成")
        XCTAssertEqual(completion.presentation.progress, 1)
        XCTAssertEqual(completion.createdAt, start.createdAt)
        XCTAssertEqual(completion.lifecycle, start.lifecycle)
        XCTAssertEqual(fixture.manager.currentSnapshot?.instanceToken, token)
        XCTAssertEqual(fixture.manager.diagnostics.activityCount, 1)
        let completionPixels = try await render(view)
        XCTAssertNotEqual(completionPixels, progressPixels)
        let versioned = try await runtime.evaluateForTesting("Object.isFrozen(island.activity.update) && island.activity.update.apiVersion === '1.0.0'")
        XCTAssertEqual(versioned, .boolean(true))
        _ = try await runtime.evaluateForTesting("mockEnd(); void 0")
        try await logMarker(fixture, pluginID: example.manifest.id, message: "mock.ended")
        XCTAssertNil(fixture.activity("build", pluginID: example.manifest.id))
        XCTAssertNil(fixture.manager.current)
    }

    func testRealJavaScriptUpdateRejectsUnsafeValuesAndMissingCapability() async throws {
        let fixture = ActivityBridgeFixture()
        defer { fixture.shutdown() }
        let source = """
            function onStart() {
                island.activity.publish({id:'build',presentation:{title:'Original'}}).then(() => {
                    const getter = {id:'build'};
                    Object.defineProperty(getter,'presentation',{enumerable:true,get(){globalThis.getterCalls++;return {title:'Getter'};}});
                    globalThis.getterCalls = 0;
                    return Promise.all([
                        island.activity.update({id:'build',presentation:{title:'NaN',progress:NaN}}),
                        island.activity.update({id:'build',presentation:{title:'Function'},actions:[{id:'open',title:'Open',handler:function(){}}]}),
                        island.activity.update(getter)
                    ].map(value => value.catch(error => error.code)));
                }).then(codes => { globalThis.safe = codes.every(code => code === 'invalidArguments') && getterCalls === 0; globalThis.done = true; });
            }
            """
        let runtime = try fixture.loadJavaScript(package(source: source))
        try await marker(runtime, "done")
        let safe = try await runtime.evaluateForTesting("safe")
        XCTAssertEqual(safe, .boolean(true))
        XCTAssertEqual(fixture.activity("build")?.presentation.title, "Original")
        let noUpdate = try fixture.loadJavaScript(package(id: "com.example.beta", source: """
            function onStart() {
                island.activity.update({id:'missing',presentation:{title:'Denied'}}).catch(error => {
                    globalThis.code = error.code; globalThis.done = true;
                });
            }
            """, capabilities: [.publishActivity]))
        try await marker(noUpdate, "done")
        let code = try await noUpdate.evaluateForTesting("code")
        XCTAssertEqual(code, .string("capabilityRequired"))
        XCTAssertNil(fixture.activity("missing", pluginID: "com.example.beta"))
    }

    // MARK: Helpers

    private func package(
        id: String = "com.example.alpha", source: String = "",
        capabilities: [PluginCapability] = [.publishActivity, .updateActivity, .endActivity, .handleActions]
    ) throws -> ValidatedPluginPackage {
        let manifest = try PluginManifest(
            id: id, name: "Activity Bridge Test", version: SemanticVersion("1.0.0"), engine: .javaScriptCore,
            entry: "index.js", minimumHostVersion: SemanticVersion("0.6.0"), permissions: [], capabilities: capabilities
        )
        let data = Data(source.utf8)
        return .init(manifest: manifest, canonicalRootURL: URL(fileURLWithPath: "/activity-bridge-tests/\(id)", isDirectory: true),
                     entryRelativePath: "index.js", entrySource: data, regularFileCount: 2, totalFileBytes: UInt64(data.count))
    }

    private func publish(_ fixture: ActivityBridgeFixture, package: ValidatedPluginPackage,
                         context: PluginExecutionContext, params: [String: Any],
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let response = try await request(fixture, package: package, context: context, method: "activity.publish", params: params)
        XCTAssertEqual(response["ok"] as? Bool, true, "\(response)", file: file, line: line)
    }

    private func request(_ fixture: ActivityBridgeFixture, package: ValidatedPluginPackage,
                         context: PluginExecutionContext, method: String, params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion": "1.0.0", "method": method, "params": params])
        return try decode(await fixture.service.handle(String(decoding: data, as: UTF8.self), package: package, context: context))
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func errorCode(_ response: [String: Any]) -> String? {
        (response["error"] as? [String: Any])?["code"] as? String
    }

    private func marker(_ runtime: PluginRuntime, _ name: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while true {
            if runtime.snapshot.state == .running {
                let marked = try await runtime.evaluateForTesting("globalThis['\(name)'] === true")
                if marked == .boolean(true) { return }
            }
            if runtime.snapshot.lastFailure != nil || ContinuousClock.now >= deadline {
                XCTFail("JavaScript marker \(name) did not settle: \(runtime.snapshot)")
                throw ActivityBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func logMarker(_ fixture: ActivityBridgeFixture, pluginID: String, message: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !fixture.service.logs(for: pluginID).contains(where: { $0.message == message }) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Fixture log \(message) did not arrive: \(fixture.service.logs(for: pluginID))")
                throw ActivityBridgeTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func render<Content: View>(_ view: NSHostingView<Content>) async throws -> Data {
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 470, pixelsHigh: 150, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = view.frame.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class ActivityBridgeFixture {
    let rateClock = ActivityBridgeRateClock()
    let activityClock = TestActivityClock(Date(timeIntervalSinceReferenceDate: 94_000))
    let service: PluginJSBridge
    let manager: ActivityManager
    let lifecycle: PluginLifecycleBridge
    private let factory: ActivityBridgeFactory

    var contexts: [PluginExecutionContext] { factory.contexts }

    init() {
        let rateClock = rateClock
        service = PluginJSBridge(activityRateClock: { rateClock.now })
        var configuration = ActivityScheduler.Configuration.immediate
        configuration.maximumQueuedNormal = 32
        manager = ActivityManager(clock: activityClock, configuration: configuration)
        let factory = ActivityBridgeFactory(service: service)
        self.factory = factory
        lifecycle = PluginLifecycleBridge(activityManager: manager, actionRouter: ActionRouter(manager: manager)) { package in
            let runtime = factory.usesJavaScript ? PluginRuntime(package: package, bridge: factory.service) : nil
            if let runtime { factory.runtimes.append(runtime) }
            return ActivityBridgeTestRuntime(factory: factory, runtime: runtime)
        }
    }

    func load(_ package: ValidatedPluginPackage) throws -> PluginExecutionContext {
        factory.usesJavaScript = false
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.contexts.last)
    }

    func loadJavaScript(_ package: ValidatedPluginPackage) throws -> PluginRuntime {
        factory.usesJavaScript = true
        lifecycle.pluginDidLoad(package, isEnabled: true)
        return try XCTUnwrap(factory.runtimes.last)
    }

    func id(_ localID: String, pluginID: String = "com.example.alpha") -> String {
        PluginJSBridge.activityID(pluginID: pluginID, localID: localID)
    }

    func activity(_ localID: String, pluginID: String = "com.example.alpha") -> IslandActivity? {
        manager.activity(id: id(localID, pluginID: pluginID))
    }

    func shutdown() { lifecycle.shutdown() }
}

@MainActor
private final class ActivityBridgeRateClock { var now: TimeInterval = 1_000 }

@MainActor
private final class ActivityBridgeFactory {
    let service: PluginJSBridge
    var usesJavaScript = false
    var contexts: [PluginExecutionContext] = []
    var runtimes: [PluginRuntime] = []

    init(service: PluginJSBridge) { self.service = service }
}

@MainActor
private final class ActivityBridgeTestRuntime: PluginLifecycleRuntime {
    let factory: ActivityBridgeFactory
    let runtime: PluginRuntime?

    init(factory: ActivityBridgeFactory, runtime: PluginRuntime?) {
        self.factory = factory
        self.runtime = runtime
    }

    func onStart(context: PluginExecutionContext) throws {
        factory.contexts.append(context)
        try runtime?.onStart(context: context)
    }

    func onStop(reason: PluginStopReason) throws { try runtime?.onStop(reason: reason) }
    func teardown() { runtime?.teardown() }
}

private struct ActivityBridgeRenderedView: View {
    @ObservedObject var manager: ActivityManager

    var body: some View {
        Group {
            if let activity = manager.current {
                IslandRenderer(presentation: activity.presentation, mode: .expanded, shellSize: .init(width: 470, height: 150))
            } else {
                Text("No Activity")
            }
        }
        .frame(width: 470, height: 150)
        .background(Color.black)
        .foregroundStyle(.white)
    }
}

private enum ActivityBridgeTestError: Error { case timedOut }
