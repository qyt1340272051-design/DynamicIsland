import Foundation
import XCTest
@testable import DynamicIsland

@MainActor
final class IslandToolMenuInteractionTests: XCTestCase {
    func testMenuAdmissionRequiresVisibleExpandedHostWithoutDragOrCompletion() throws {
        let fixture = try ToolMenuInteractionFixture(expand: false)
        defer { fixture.shutdown() }
        let model = fixture.model
        XCTAssertNil(model.beginToolMenuInteraction())

        model.setHovering(true)
        XCTAssertEqual(model.expandedSurface, .music)
        let musicMenu = try XCTUnwrap(model.beginToolMenuInteraction())
        XCTAssertTrue(model.isToolMenuInteractionCurrent(musicMenu),
                      "The Host chooser can be opened from the expanded music surface.")
        model.cancelToolMenuInteraction(musicMenu)

        model.setIslandPanelVisible(false)
        XCTAssertNil(model.beginToolMenuInteraction())
        model.setIslandPanelVisible(true)
        model.setHovering(true)
        model.setDragging(true)
        XCTAssertNil(model.beginToolMenuInteraction())
        model.setDragging(false)
        fixture.presentCompletion()
        XCTAssertTrue(model.isTimerCompletionPresented)
        XCTAssertNil(model.beginToolMenuInteraction())
    }

    func testPointerCanLeaveForMenuAndChooseAnotherToolBeforeGraceExpires() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let first = try fixture.tool("alpha")
        let second = try fixture.tool("beta")
        XCTAssertTrue(fixture.runtime.selectTool(first))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())

        fixture.model.endHovering()
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.presentationState, .expanded)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, first.instanceToken)

        XCTAssertTrue(fixture.runtime.selectTool(second),
                      "A chooser action outside the physical island must still reach the expanded Runtime.")
        XCTAssertEqual(fixture.runtime.manager.currentSnapshot?.instanceToken, second.instanceToken)
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(second), .handled)
        XCTAssertEqual(fixture.handledActions[second.activity.id], 1)

        fixture.model.endToolMenuInteraction(menu)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, second.instanceToken)
        try await waitUntil { fixture.model.presentationState == .compact }
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(fixture.model.isToolMenuInteractionCurrent(menu))
        XCTAssertEqual(fixture.dispatch(second), .inactiveActivity)
    }

    func testReturningDuringGracePreservesSurfaceSelectionAndExpansionFeedbackCount() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let feedbackCount = fixture.haptics.expansionCount
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.model.endToolMenuInteraction(menu)

        fixture.model.beginHoveringAfterDelay()
        XCTAssertTrue(fixture.model.isPointerInside)
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        XCTAssertEqual(fixture.haptics.expansionCount, feedbackCount)
        try await remainsTrue(for: .milliseconds(90)) {
            fixture.model.presentationState == .expanded
                && fixture.model.expandedSurface == .tools
                && fixture.runtime.manager.selectedToolSnapshot?.instanceToken == tool.instanceToken
                && fixture.haptics.expansionCount == feedbackCount
        }
        XCTAssertEqual(fixture.dispatch(tool), .handled)

        fixture.model.endHovering()
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testMenuCloseWithStaleInsidePointerStillGrantsReturnPeriodAfterExit() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        XCTAssertTrue(fixture.model.isPointerInside)

        // AppKit can close its menu before the panel's default-mode pointer
        // observer catches up with the real exit.
        fixture.model.endToolMenuInteraction(menu)
        fixture.model.endHovering()
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        try await waitUntil { fixture.model.presentationState == .compact }
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testBriefReturnThenExitKeepsOriginalMenuGraceAndToolSelection() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.model.endToolMenuInteraction(menu)

        // A sampled inside value immediately after menu close may be followed
        // by an outside value before the user has returned to the island.
        fixture.model.beginHoveringAfterDelay()
        fixture.model.endHovering()
        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertTrue(fixture.model.isToolMenuInteractionCurrent(menu))
        XCTAssertTrue(fixture.model.isHovering)
        XCTAssertEqual(fixture.model.presentationState, .expanded)
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        XCTAssertEqual(fixture.dispatch(tool), .handled)

        try await waitUntil { !fixture.model.isToolMenuInteractionCurrent(menu) }
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testCloseWithInsidePointerThenRepeatedReturnsCannotConsumeOrExtendOriginalGrace() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        XCTAssertTrue(fixture.model.isPointerInside)
        fixture.model.endToolMenuInteraction(menu)
        fixture.model.endHovering()
        fixture.model.beginHoveringAfterDelay()
        fixture.model.endHovering()
        XCTAssertTrue(fixture.model.isToolMenuInteractionCurrent(menu))
        XCTAssertEqual(fixture.model.presentationState, .expanded)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)

        // Keep delivering inside/outside samples while waiting. A return must
        // neither consume the hold immediately nor restart its original timer.
        // The generous deadline checks eventual expiry without asserting an
        // exact scheduling interval for the fixture's 40 ms return period.
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while fixture.model.isToolMenuInteractionCurrent(menu) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Pointer sampling kept extending the original menu return period.")
                throw ToolMenuInteractionTestError.timedOut
            }
            fixture.model.beginHoveringAfterDelay()
            fixture.model.endHovering()
            XCTAssertTrue(fixture.model.isToolMenuInteractionCurrent(menu))
            XCTAssertFalse(fixture.model.isPointerInside)
            XCTAssertTrue(fixture.model.isHovering)
            XCTAssertEqual(fixture.model.presentationState, .expanded)
            XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
            try await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertFalse(fixture.model.isPointerInside)
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testDeadlinePointerRefreshCorrectsStaleOutsideAndPreservesToolUntilNormalExit() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer {
            fixture.model.refreshPointerContainmentBeforeToolMenuReturn = nil
            fixture.shutdown()
        }
        let model = fixture.model
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(model.beginToolMenuInteraction())
        model.endHovering()
        XCTAssertFalse(model.isPointerInside)
        var refreshCount = 0
        model.refreshPointerContainmentBeforeToolMenuReturn = { [weak model] in
            guard let model else { return }
            refreshCount += 1
            XCTAssertTrue(model.isToolMenuInteractionCurrent(menu))
            XCTAssertFalse(model.isPointerInside)
            // Model the controller observing the actual pointer inside at the
            // deadline. This does not move or inspect the physical mouse.
            model.beginHoveringAfterDelay()
        }
        model.endToolMenuInteraction(menu)

        try await waitUntil { refreshCount == 1 && !model.isToolMenuInteractionCurrent(menu) }
        XCTAssertTrue(model.isPointerInside)
        XCTAssertTrue(model.isHovering)
        XCTAssertEqual(model.presentationState, .expanded)
        XCTAssertEqual(model.expandedSurface, .tools)
        XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, tool.instanceToken)
        XCTAssertEqual(fixture.dispatch(tool), .handled)

        model.endHovering()
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
        XCTAssertEqual(refreshCount, 1)
    }

    func testDeadlinePointerRefreshCorrectsStaleInsideAndRevokesSelectedTool() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer {
            fixture.model.refreshPointerContainmentBeforeToolMenuReturn = nil
            fixture.shutdown()
        }
        let model = fixture.model
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(model.beginToolMenuInteraction())
        XCTAssertTrue(model.isPointerInside)
        var refreshCount = 0
        model.refreshPointerContainmentBeforeToolMenuReturn = { [weak model] in
            guard let model else { return }
            refreshCount += 1
            XCTAssertTrue(model.isToolMenuInteractionCurrent(menu))
            XCTAssertTrue(model.isPointerInside)
            model.endHovering()
            XCTAssertTrue(model.isHovering, "The current token still holds expansion during refresh.")
        }
        model.endToolMenuInteraction(menu)

        try await waitUntil { refreshCount == 1 && !model.isToolMenuInteractionCurrent(menu) }
        XCTAssertFalse(model.isPointerInside)
        XCTAssertFalse(model.isHovering)
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
        XCTAssertEqual(refreshCount, 1)
    }

    func testDeadlinePointerRefreshHideCannotRestoreOldSelection() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer {
            fixture.model.refreshPointerContainmentBeforeToolMenuReturn = nil
            fixture.shutdown()
        }
        let model = fixture.model
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(model.beginToolMenuInteraction())
        model.endHovering()
        var refreshCount = 0
        model.refreshPointerContainmentBeforeToolMenuReturn = { [weak model] in
            guard let model else { return }
            refreshCount += 1
            XCTAssertTrue(model.isToolMenuInteractionCurrent(menu))
            model.setIslandPanelVisible(false)
        }
        model.endToolMenuInteraction(menu)

        try await waitUntil { refreshCount == 1 }
        try await remainsTrue(for: .milliseconds(70)) {
            !model.isIslandPanelVisible
                && !model.isToolMenuInteractionCurrent(menu)
                && !model.isPointerInside
                && !model.isHovering
                && fixture.runtime.manager.selectedToolSnapshot == nil
        }
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
        model.setIslandPanelVisible(true)
        XCTAssertEqual(model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(refreshCount, 1)
    }

    func testDeadlinePointerRefreshReopenCannotReleaseReplacementTokenOrSelection() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer {
            fixture.model.refreshPointerContainmentBeforeToolMenuReturn = nil
            fixture.shutdown()
        }
        let model = fixture.model
        let runtime = fixture.runtime
        let first = try fixture.tool("alpha")
        let second = try fixture.tool("beta")
        XCTAssertTrue(runtime.selectTool(first))
        let original = try XCTUnwrap(model.beginToolMenuInteraction())
        model.endHovering()
        var refreshCount = 0
        var replacement: UUID?
        model.refreshPointerContainmentBeforeToolMenuReturn = { [weak model, weak runtime] in
            guard let model, let runtime else { return }
            refreshCount += 1
            XCTAssertTrue(model.isToolMenuInteractionCurrent(original))
            replacement = model.beginToolMenuInteraction()
            XCTAssertTrue(runtime.selectTool(second))
        }
        model.endToolMenuInteraction(original)

        try await waitUntil { refreshCount == 1 }
        let reopened = try XCTUnwrap(replacement)
        XCTAssertNotEqual(original, reopened)
        try await remainsTrue(for: .milliseconds(90)) {
            model.isToolMenuInteractionCurrent(reopened)
                && !model.isToolMenuInteractionCurrent(original)
                && !model.isPointerInside
                && model.isHovering
                && model.presentationState == .expanded
                && runtime.manager.selectedToolSnapshot?.instanceToken == second.instanceToken
        }
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        XCTAssertEqual(fixture.dispatch(second), .handled)
        XCTAssertEqual(refreshCount, 1, "The replacement is still tracking, so it has no return deadline yet.")

        model.refreshPointerContainmentBeforeToolMenuReturn = nil
        model.endToolMenuInteraction(reopened)
        try await waitUntil { model.presentationState == .compact }
        XCTAssertFalse(model.isToolMenuInteractionCurrent(reopened))
        XCTAssertNil(runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(second), .inactiveActivity)
    }

    func testCompletionTransfersToHostGraceBeforeSelectionAndControlLifetimeChanges() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let first = try fixture.tool("alpha")
        let second = try fixture.tool("beta")
        XCTAssertTrue(fixture.runtime.selectTool(first))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        var callbacks: [String] = []
        var enteredGraceBeforeSelection = false
        var oldControlIsAttached = true

        IslandToolMenuCompletion.complete(session: menu, onEnded: { id in
            callbacks.append("end")
            XCTAssertEqual(id, menu)
            fixture.model.endToolMenuInteraction(id)
            enteredGraceBeforeSelection = fixture.model.isToolMenuInteractionCurrent(id)
        }, isCurrent: { id in
            callbacks.append("isCurrent")
            // The Host token, rather than a native control's lifetime, owns
            // validity after tracking ends.
            return fixture.model.isToolMenuInteractionCurrent(id)
        }, selection: {
            callbacks.append("selection")
            XCTAssertTrue(enteredGraceBeforeSelection)
            XCTAssertFalse(fixture.model.isPointerInside)
            XCTAssertEqual(fixture.model.presentationState, .expanded)
            XCTAssertTrue(fixture.runtime.selectTool(second))

            // Simulate a callback rebuilding its control. This is a lifetime
            // spy, not a real AppKit Coordinator reconstruction test.
            oldControlIsAttached = false
            XCTAssertTrue(fixture.model.isToolMenuInteractionCurrent(menu))
            XCTAssertEqual(fixture.runtime.manager.selectedToolSnapshot?.instanceToken, second.instanceToken)
            XCTAssertEqual(fixture.dispatch(second), .handled)
        })

        XCTAssertEqual(callbacks, ["end", "isCurrent", "selection"])
        XCTAssertTrue(enteredGraceBeforeSelection)
        XCTAssertFalse(oldControlIsAttached)
        XCTAssertTrue(fixture.model.isToolMenuInteractionCurrent(menu))
        XCTAssertEqual(fixture.model.expandedSurface, .tools)
        XCTAssertEqual(fixture.dispatch(first), .inactiveActivity)
        XCTAssertEqual(fixture.handledActions[second.activity.id], 1)

        try await waitUntil { !fixture.model.isToolMenuInteractionCurrent(menu) }
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(second), .inactiveActivity)
    }

    func testCompletionSkipsSelectionWhenEndingTrackingHidesOrDragsHost() throws {
        enum Interruption: CaseIterable { case hide, drag }
        for interruption in Interruption.allCases {
            let fixture = try ToolMenuInteractionFixture()
            defer { fixture.shutdown() }
            let first = try fixture.tool("alpha")
            let second = try fixture.tool("beta")
            XCTAssertTrue(fixture.runtime.selectTool(first))
            let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
            fixture.model.endHovering()
            var callbacks: [String] = []
            var didSelect = false

            IslandToolMenuCompletion.complete(session: menu, onEnded: { id in
                callbacks.append("end")
                fixture.model.endToolMenuInteraction(id)
                switch interruption {
                case .hide: fixture.model.setIslandPanelVisible(false)
                case .drag: fixture.model.setDragging(true)
                }
            }, isCurrent: { id in
                callbacks.append("isCurrent")
                return fixture.model.isToolMenuInteractionCurrent(id)
            }, selection: {
                callbacks.append("selection")
                didSelect = true
                _ = fixture.runtime.selectTool(second)
            })

            XCTAssertEqual(callbacks, ["end", "isCurrent"], "\(interruption)")
            XCTAssertFalse(didSelect, "\(interruption)")
            XCTAssertFalse(fixture.model.isToolMenuInteractionCurrent(menu), "\(interruption)")
            XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot, "\(interruption)")
            XCTAssertEqual(fixture.dispatch(first), .inactiveActivity, "\(interruption)")
            XCTAssertEqual(fixture.dispatch(second), .inactiveActivity, "\(interruption)")
        }
    }

    func testReopenedMenuRejectsOldCloseCancelAndDeadline() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let old = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.model.endToolMenuInteraction(old)
        let replacement = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        XCTAssertNotEqual(old, replacement)
        fixture.model.endToolMenuInteraction(old)
        fixture.model.cancelToolMenuInteraction(old)

        try await remainsTrue(for: .milliseconds(90)) {
            fixture.model.isToolMenuInteractionCurrent(replacement)
                && !fixture.model.isToolMenuInteractionCurrent(old)
                && fixture.model.presentationState == .expanded
                && fixture.runtime.manager.selectedToolSnapshot?.instanceToken == tool.instanceToken
        }
        fixture.model.endToolMenuInteraction(replacement)
        try await waitUntil { fixture.model.presentationState == .compact }
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
    }

    func testExplicitCancellationReleasesHoldAndLateCloseCannotRestoreSelection() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.model.cancelToolMenuInteraction(menu)
        XCTAssertFalse(fixture.model.isToolMenuInteractionCurrent(menu))
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        fixture.model.endToolMenuInteraction(menu)
        try await remainsTrue(for: .milliseconds(70)) {
            fixture.model.presentationState == .compact
                && fixture.runtime.manager.selectedToolSnapshot == nil
        }
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testHideInvalidatesMenuAndLateCloseOrHoverCannotReviveHiddenPanel() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.model.endToolMenuInteraction(menu)
        fixture.model.setIslandPanelVisible(false)
        fixture.model.endToolMenuInteraction(menu)
        fixture.model.beginHoveringAfterDelay()
        XCTAssertNil(fixture.model.beginToolMenuInteraction())

        try await remainsTrue(for: .milliseconds(70)) {
            !fixture.model.isIslandPanelVisible
                && !fixture.model.isPointerInside
                && !fixture.model.isHovering
                && !fixture.model.isToolMenuInteractionCurrent(menu)
                && fixture.runtime.manager.selectedToolSnapshot == nil
        }
        fixture.model.setIslandPanelVisible(true)
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testDragNonToolsSurfaceCompletionAndShutdownInvalidateCurrentMenu() throws {
        enum Interruption: CaseIterable { case dragging, music, fileTray, completion, shutdown }
        for interruption in Interruption.allCases {
            let fixture = try ToolMenuInteractionFixture()
            defer { fixture.shutdown() }
            let tool = try fixture.tool("alpha")
            XCTAssertTrue(fixture.runtime.selectTool(tool))
            let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
            fixture.model.endHovering()
            switch interruption {
            case .dragging: fixture.model.setDragging(true)
            case .music: fixture.model.selectExpandedSurface(.music)
            case .fileTray: fixture.model.selectExpandedSurface(.fileTray)
            case .completion: fixture.presentCompletion()
            case .shutdown: fixture.shutdown()
            }
            XCTAssertFalse(fixture.model.isToolMenuInteractionCurrent(menu), "\(interruption)")
            XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot, "\(interruption)")
            XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity, "\(interruption)")
            fixture.model.endToolMenuInteraction(menu)
            XCTAssertFalse(fixture.model.isToolMenuInteractionCurrent(menu), "A late close cannot undo \(interruption).")
            XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        }
    }

    func testNormalPointerExitAndLegacyPageChoiceStillRevokeOldToolActions() throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let tool = try fixture.tool("alpha")
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        XCTAssertEqual(fixture.dispatch(tool), .handled)
        fixture.model.endHovering()
        XCTAssertEqual(fixture.model.presentationState, .compact)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)

        fixture.model.setHovering(true)
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        fixture.runtime.selectLegacySurface(.music)
        XCTAssertEqual(fixture.model.expandedSurface, .music)
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertEqual(fixture.dispatch(tool), .inactiveActivity)
    }

    func testDisabledPluginCannotBeChosenOrInvokedByMenuRetainedSnapshot() async throws {
        let fixture = try ToolMenuInteractionFixture()
        defer { fixture.shutdown() }
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/examples", isDirectory: true)
        let package = try PluginValidator().validateExpandedPackage(at: examples.appendingPathComponent("tool-demo"),
            context: .init(hostVersion: SemanticVersion("0.6.0"), occupiedPluginIDs: [], allowedContainerURL: examples))
        fixture.runtime.pluginLifecycle.pluginDidLoad(package, isEnabled: true)
        try await waitUntil {
            fixture.runtime.manager.toolSnapshots.contains { $0.activity.source.identifier == package.manifest.id }
        }
        let tool = try XCTUnwrap(fixture.runtime.manager.toolSnapshots.first {
            $0.activity.source.identifier == package.manifest.id
        })
        XCTAssertTrue(fixture.runtime.selectTool(tool))
        let menu = try XCTUnwrap(fixture.model.beginToolMenuInteraction())
        fixture.model.endHovering()
        fixture.runtime.pluginLifecycle.pluginDidChangeEnablement(id: package.manifest.id, isEnabled: false)

        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(fixture.runtime.selectTool(tool))
        XCTAssertEqual(fixture.dispatch(tool, actionID: "increment"), .inactiveActivity)
        fixture.model.endToolMenuInteraction(menu)
        try await waitUntil { fixture.model.presentationState == .compact }
        XCTAssertNil(fixture.runtime.manager.selectedToolSnapshot)
        XCTAssertFalse(fixture.runtime.pluginLifecycle.allowsExecution(id: package.manifest.id))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Menu state did not settle before the bounded deadline.", file: file, line: line)
                throw ToolMenuInteractionTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func remainsTrue(for duration: Duration, _ condition: @MainActor () -> Bool,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: duration)
        repeat {
            guard condition() else {
                XCTFail("A stale callback changed the protected menu state.", file: file, line: line)
                throw ToolMenuInteractionTestError.changedState
            }
            try await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
    }
}

@MainActor
private final class ToolMenuInteractionFixture {
    let model: IslandViewModel
    let runtime: IslandActivityRuntime
    let haptics: ToolMenuHapticService
    var handledActions: [String: Int] = [:]
    private var didShutdown = false

    init(expand: Bool = true) throws {
        let haptics = ToolMenuHapticService()
        self.haptics = haptics
        model = IslandViewModel(volumeService: ToolMenuVolumeService(), fileTrayService: ToolMenuFileTrayService(),
            sharingService: ToolMenuSharingService(), musicService: PlaceholderMusicControlService(),
            hapticFeedbackService: haptics, hoverExpansionDelayNanoseconds: 20_000_000,
            toolMenuReturnDelayNanoseconds: 40_000_000)
        runtime = IslandActivityRuntime(viewModel: model)
        for name in ["alpha", "beta"] {
            let id = "menu-tool-\(name)"
            let source = ActivitySource(kind: .builtIn, identifier: id)
            try runtime.manager.publish(.init(id: id, source: source, priority: .background,
                lifecycle: .init(policy: .persistent),
                presentation: .init(title: id, expanded: .button(.init(actionID: "run", label: .text(.init("Run")))),
                                    showsCompact: false, role: .tool),
                createdAt: Date(), actions: [.init(id: "run", title: "Run")]))
            runtime.router.register(source: source) { [weak self] _ in
                guard let self else { return }
                self.handledActions[id, default: 0] += 1
            }
        }
        if expand {
            model.setHovering(true)
            model.selectExpandedSurface(.tools)
        }
    }

    func tool(_ name: String) throws -> ActivitySnapshot {
        try XCTUnwrap(runtime.manager.toolSnapshots.first { $0.activity.id == "menu-tool-\(name)" })
    }

    func dispatch(_ snapshot: ActivitySnapshot, actionID: String = "run") -> ActionDispatchResult {
        runtime.router.dispatch(id: snapshot.activity.id, source: snapshot.activity.source,
            instanceToken: snapshot.instanceToken, action: .init(actionID: actionID, value: .none))
    }

    func presentCompletion() {
        let start = Date()
        model.timerTools.selectedMode = .countdown
        model.timerTools.startSelectedTimer(at: start)
        model.timerTools.refresh(at: start.addingTimeInterval(model.timerTools.countdownDuration + 1))
    }

    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        runtime.shutdownPlugins()
    }
}

private struct ToolMenuVolumeService: VolumeService {
    func currentVolume() throws -> Float { 0.5 }
    func setVolume(_ volume: Float) throws {}
}

private struct ToolMenuFileTrayService: FileTrayService {
    func importFiles(from urls: [URL]) throws -> [TrayFileItem] { [] }
    func remove(_ item: TrayFileItem) throws {}
    func clear() throws {}
}

private struct ToolMenuSharingService: SharingService {
    func share(urls: [URL]) throws {}
}

private final class ToolMenuHapticService: HapticFeedbackService {
    private(set) var expansionCount = 0
    func performExpansionFeedback() { expansionCount += 1 }
}

private enum ToolMenuInteractionTestError: Error { case timedOut, changedState }
