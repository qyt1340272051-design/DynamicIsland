import Foundation
import XCTest
@testable import DynamicIsland

final class SuperIslandModuleConverterTests: XCTestCase {
    func testManifestTitleStillHonorsOrdinaryActivityUTF8Bound() throws {
        let value = module(text("A"), text("B"))
        let boundary = String(repeating: "😀", count: 64)
        XCTAssertEqual(boundary.utf8.count, 256)
        XCTAssertEqual(try SuperIslandModuleConverter.convert(value, title: boundary).presentation.title, boundary)
        for title in [String(repeating: "a", count: 257), String(repeating: "😀", count: 80)] {
            XCTAssertThrowsError(try SuperIslandModuleConverter.convert(value, title: title)) {
                XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded)
            }
        }
    }

    func testModuleCannotSupplyHostIdentityLifetimePriorityOrPresentationPolicy() throws {
        let value = module(text("Small"), text("Details"))
        let result = try SuperIslandModuleConverter.convert(value, title: "Host manifest name")
        let request = result.request(isUpdate: false)
        let source = ActivitySource(kind: .plugin, identifier: "com.example.compatible")
        let activity = try request.materialize(source: source, namespacedID: "host-owned-id", now: .distantPast)
        XCTAssertEqual(activity.id, "host-owned-id")
        XCTAssertEqual(activity.source, source)
        XCTAssertEqual(activity.priority, .background)
        XCTAssertEqual(activity.lifecycle.policy, .persistent)
        XCTAssertEqual(activity.presentation.title, "Host manifest name")
        XCTAssertEqual(activity.presentation.compact, .text(.init("Small")))
        XCTAssertEqual(activity.presentation.expanded, .text(.init("Details")))
        XCTAssertEqual(activity.presentation.role, .tool)
        XCTAssertEqual(activity.presentation.compactPolicy, .selectedOnly)
        XCTAssertEqual(result.limitations, [.hostTextTypography, .hostTextLineLimit])
        for field in ["id", "source", "priority", "lifecycle", "presentation", "permissions"] {
            guard case .object(var fields) = value else { return XCTFail("Expected object") }
            fields[field] = .string("override")
            XCTAssertThrowsError(try SuperIslandModuleConverter.convert(.object(fields), title: "Host")) {
                XCTAssertEqual($0 as? PluginBridgeErrorCode, .invalidArguments)
            }
        }
    }

    func testActionUnionDeduplicatesAcrossLayoutsAndKeepsEightActionHostBound() throws {
        let compact = stack((0..<4).map { button("action\($0)") })
        let expanded = stack((0..<8).map { button("action\($0)") })
        let result = try SuperIslandModuleConverter.convert(module(compact, expanded), title: "Host")
        XCTAssertEqual(result.actions.map(\.id), (0..<8).map { "action\($0)" })
        XCTAssertTrue(result.limitations.contains(.hostButtonAppearance))
        XCTAssertThrowsError(try SuperIslandModuleConverter.convert(
            module(compact, stack((0..<9).map { button("action\($0)") })), title: "Host")) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded)
        }
    }

    func testMalformedSecondLayoutRejectsEntireModuleAndCannotLeavePartialConversion() {
        let malformed: [PluginBridgeJSON] = [.null, .array([]), .object(["compact": text("A")]),
            module(text("A"), .object(["type": .string("NSView")])),
            module(text("A"), .object(["type": .string("progress"), "value": .number(2)]))]
        for value in malformed {
            XCTAssertThrowsError(try SuperIslandModuleConverter.convert(value, title: "Host")) {
                XCTAssertEqual($0 as? PluginBridgeErrorCode, .invalidArguments)
            }
        }
        XCTAssertThrowsError(try SuperIslandModuleConverter.convert(
            module(text("A"), text(String(repeating: "a", count: 257))), title: "Host")) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded)
        }
    }

    private func module(_ compact: PluginBridgeJSON, _ expanded: PluginBridgeJSON) -> PluginBridgeJSON {
        .object(["compact": compact, "expanded": expanded])
    }
    private func text(_ value: String) -> PluginBridgeJSON { .object(["type": .string("text"), "value": .string(value)]) }
    private func button(_ action: String) -> PluginBridgeJSON {
        .object(["type": .string("button"), "label": text(action), "action": .string(action)])
    }
    private func stack(_ children: [PluginBridgeJSON]) -> PluginBridgeJSON {
        .object(["type": .string("vstack"), "children": .array(children)])
    }
}
