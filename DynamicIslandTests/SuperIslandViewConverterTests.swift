import Foundation
import XCTest
@testable import DynamicIsland

final class SuperIslandViewConverterTests: XCTestCase {
    func testSixProtocolKindsUseActualUpstreamFieldNamesAndHostSchema() throws {
        // Independently authored protocol fixture, not a copied upstream plugin.
        let result = try SuperIslandViewConverter.convertJSON(#"""
            {"type":"vstack","children":[
              {"type":"hstack","children":[
                {"type":"icon","name":"bolt.fill","size":14},
                {"type":"text","value":"Build ready","style":"body"}
              ]},
              {"type":"progress","value":3,"total":4},
              {"type":"button","action":"open_build","label":{"type":"text","value":"Open"}}
            ]}
            """#)
        let expected: IslandNode = .vStack(.init([
            .hStack(.init([.icon(.init("bolt.fill")), .text(.init("Build ready"))])),
            .progress(.init(0.75, color: .primary)),
            .button(.init(actionID: "open_build", label: .text(.init("Open"))))
        ]))
        XCTAssertEqual(result.node, expected)
        XCTAssertEqual(result.actionIDs, ["open_build"])
        XCTAssertEqual(result.limitations, [
            .hostTextTypography, .hostTextLineLimit, .hostIconAppearance,
            .hostStackSpacing, .hostStackAlignment, .hostButtonAppearance
        ])
        XCTAssertEqual(try IslandNode.decodeJSON(result.node.encodeJSON()), expected)
    }

    func testKnownAppearanceOptionsProduceTypedLimitationsAndNeverNativeStyles() throws {
        let input: PluginBridgeJSON = .object([
            "type": .string("vstack"), "spacing": .number(16), "align": .string("trailing"),
            "distribution": .string("fillEqually"), "children": .array([
                .object(["type": .string("text"), "value": .string("Status"),
                         "style": .string("largeTitle"), "lineLimit": .number(2), "color": .string("green")]),
                .object(["type": .string("icon"), "name": .string("checkmark.circle.fill"),
                         "size": .number(32), "color": .string("red")])
            ])
        ])
        let result = try SuperIslandViewConverter.convert(input)
        XCTAssertEqual(result.node, .vStack(.init([
            .text(.init("Status", color: .success)), .icon(.init("checkmark.circle.fill"))
        ])))
        XCTAssertEqual(result.limitations, [
            .hostTextTypography, .hostTextLineLimit, .hostIconAppearance, .hostStackSpacing,
            .hostStackAlignment, .hostStackDistribution, .semanticColors
        ])
        let hostJSON = try result.node.encodeJSON()
        for field in ["largeTitle", "lineLimit", "spacing", "distribution", "trailing"] {
            XCTAssertFalse(String(decoding: hostJSON, as: UTF8.self).contains(field))
        }
    }

    func testNamedColorsUseOnlyFiniteHostTokensAndUnknownOrRGBAColorsAreRejected() throws {
        let colors: [(String, IslandSemanticColorToken)] = [
            ("white", .primary), ("gray", .secondary), ("red", .danger), ("green", .success),
            ("blue", .accent), ("yellow", .warning), ("orange", .warning)
        ]
        for (name, expected) in colors {
            let result = try SuperIslandViewConverter.convert(.object([
                "type": .string("text"), "value": .string("Status"), "color": .string(name)
            ]))
            XCTAssertEqual(result.node, .text(.init("Status", color: expected)))
            XCTAssertEqual(result.limitations.contains(.semanticColors), name != "white")
        }
        for color: PluginBridgeJSON in [
            .string("#ffffff"), .string("primary"), .string("purple"),
            .object(["r": .number(1), "g": .number(0), "b": .number(0), "a": .number(1)])
        ] {
            assertError(.unsupportedValue) {
                try SuperIslandViewConverter.convert(.object([
                    "type": .string("progress"), "value": .number(0.5), "color": color
                ]))
            }
        }
    }

    func testProgressNormalizesTotalWithoutClampingAndPreservesBoundaryFractions() throws {
        let samples: [(Double, Double, Double)] = [
            (0, 3, 0), (1, 3, 1 / 3), (750, 1_000, 0.75), (3, 3, 1),
            (.leastNonzeroMagnitude, .leastNonzeroMagnitude, 1),
            (.greatestFiniteMagnitude, .greatestFiniteMagnitude, 1)
        ]
        for (amount, total, expected) in samples {
            let result = try SuperIslandViewConverter.convert(progress(amount, total: total))
            guard case .progress(let value) = result.node else { return XCTFail("Expected progress") }
            XCTAssertEqual(value.value, expected, accuracy: 1e-15)
            XCTAssertEqual(value.style, .linear)
            XCTAssertEqual(value.color, .primary, "Upstream omitted color defaults to white.")
        }
        XCTAssertEqual(try SuperIslandViewConverter.convert(progress(0.5)).node,
                       .progress(.init(0.5, color: .primary)))
        for input in [progress(-0.1), progress(1.1), progress(2, total: 1),
                      progress(0, total: 0), progress(0, total: -1),
                      progress(.nan), progress(.infinity), progress(0, total: .infinity)] {
            assertError(.invalidArguments) { try SuperIslandViewConverter.convert(input) }
        }
    }

    func testMissingFieldsNullAndWrongPrimitiveTypesAreRejectedWithoutCoercion() {
        let malformed: [PluginBridgeJSON] = [
            .null, .array([]), .string("text"), .object([:]),
            .object(["type": .string("text")]),
            .object(["type": .string("text"), "value": .number(5)]),
            .object(["type": .string("text"), "value": .string("Text"), "style": .null]),
            .object(["type": .string("icon"), "name": .null]),
            .object(["type": .string("icon"), "name": .string("star"), "size": .string("14")]),
            .object(["type": .string("hstack"), "children": .null]),
            .object(["type": .string("hstack"), "children": .array([.null])]),
            .object(["type": .string("progress"), "value": .boolean(true)]),
            .object(["type": .string("progress"), "value": .number(0.5), "total": .null]),
            .object(["type": .string("button"), "action": .string("open"), "label": .null]),
            .object(["type": .string("button"), "action": .number(5), "label": text("Open")])
        ]
        for input in malformed {
            assertError(.invalidArguments) { try SuperIslandViewConverter.convert(input) }
        }
    }

    func testUnsupportedNodesAndPropertiesFailInsteadOfSilentlyProducingPartialTrees() {
        for kind in ["NSView", "webView", "image", "zstack", "spacer", "toggle", "slider", "countdown", "hStack"] {
            assertError(.unsupportedNode) {
                try SuperIslandViewConverter.convert(.object(["type": .string(kind)]))
            }
        }
        for key in ["frame", "font", "nativeObject", "selector", "callback", "unknown"] {
            assertError(.unsupportedProperty) {
                try SuperIslandViewConverter.convert(.object([
                    "type": .string("text"), "value": .string("Text"), key: .string("untrusted")
                ]))
            }
        }
        assertError(.invalidArguments) {
            try SuperIslandViewConverter.convert(.object([
                "type": .string("text"), "value": .string("Text"), "toJSON": .string("untrusted")
            ]))
        }
        assertError(.unsupportedProperty) {
            try SuperIslandViewConverter.convert(.object([
                "type": .string("button"), "label": text("Open"),
                "action": .string("open"), "actionID": .string("different")
            ]))
        }
        assertError(.unsupportedNode) {
            try SuperIslandViewConverter.convert(.object([
                "type": .string("hstack"), "children": .array([
                    text("Valid sibling"), .object(["type": .string("NSView")])
                ])
            ]))
        }
    }

    func testAppearanceVocabularyRejectsUnboundedOrUnrecognizedValues() {
        let unsupported: [PluginBridgeJSON] = [
            .object(["type": .string("text"), "value": .string("Text"), "style": .string("customFont")]),
            .object(["type": .string("text"), "value": .string("Text"), "lineLimit": .number(0)]),
            .object(["type": .string("text"), "value": .string("Text"), "lineLimit": .number(1.5)]),
            .object(["type": .string("text"), "value": .string("Text"), "lineLimit": .number(17)]),
            .object(["type": .string("icon"), "name": .string("star"), "size": .number(1_000)]),
            .object(["type": .string("hstack"), "children": .array([]), "spacing": .number(6)]),
            .object(["type": .string("hstack"), "children": .array([]), "align": .string("leading")]),
            .object(["type": .string("vstack"), "children": .array([]), "align": .string("top")]),
            .object(["type": .string("vstack"), "children": .array([]), "distribution": .string("absolute")])
        ]
        for input in unsupported {
            assertError(.unsupportedValue) { try SuperIslandViewConverter.convert(input) }
        }
    }

    func testTreeDepthAndNodeQuotasIncludeButtonLabelsAndAllSiblings() throws {
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(nested(text("Leaf"), depth: 8)))
        assertError(.quotaExceeded) {
            try SuperIslandViewConverter.convert(nested(text("Leaf"), depth: 9))
        }
        var buttons = text("Label")
        for _ in 1..<IslandNode.Limits.maxDepth {
            buttons = .object(["type": .string("button"), "action": .string("open"), "label": buttons])
        }
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(buttons))
        assertError(.quotaExceeded) {
            try SuperIslandViewConverter.convert(.object([
                "type": .string("button"), "action": .string("open"), "label": buttons
            ]))
        }
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(countedTree(nodes: 128)))
        assertError(.quotaExceeded) { try SuperIslandViewConverter.convert(countedTree(nodes: 129)) }
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(.object([
            "type": .string("hstack"), "children": .array(Array(repeating: text(""), count: 16))
        ])))
        assertError(.quotaExceeded) {
            try SuperIslandViewConverter.convert(.object([
                "type": .string("hstack"), "children": .array(Array(repeating: text(""), count: 17))
            ]))
        }
    }

    func testUTF8AndIdentifierLimitsAgreeWithExistingPluginActionPolicy() throws {
        let boundary = String(repeating: "界", count: 85) + "a"
        XCTAssertEqual(boundary.utf8.count, IslandNode.Limits.maxTextBytes)
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(text(boundary)))
        assertError(.quotaExceeded) { try SuperIslandViewConverter.convert(text(boundary + "a")) }
        XCTAssertNoThrow(try SuperIslandViewConverter.convert(icon(String(repeating: "a", count: 128))))
        assertError(.quotaExceeded) {
            try SuperIslandViewConverter.convert(icon(String(repeating: "a", count: 129)))
        }
        let exactAction = String(repeating: "a", count: 80)
        XCTAssertEqual(try SuperIslandViewConverter.convert(button(exactAction)).actionIDs, [exactAction])
        assertError(.quotaExceeded) {
            try SuperIslandViewConverter.convert(button(exactAction + "a"))
        }
        for id in ["", "../secret", "https://example.com", "a/b", "open:other", "界"] {
            assertError(.invalidArguments) { try SuperIslandViewConverter.convert(button(id)) }
        }
        for name in ["", "../asset", "file:///secret", "https://example.com/icon"] {
            assertError(.invalidArguments) { try SuperIslandViewConverter.convert(icon(name)) }
        }
    }

    func testJSONEntryRejectsDuplicateKeysAndEnforcesOriginalWireBudget() throws {
        for source in [
            #"{"type":"text","value":"first","value":"second"}"#,
            #"{"type":"button","action":"open","label":{"type":"text","value":"a","value":"b"}}"#,
            #"{"type":"progress","value":NaN}"#
        ] {
            assertError(.invalidArguments) { try SuperIslandViewConverter.convertJSON(source) }
        }
        let base = #"{"type":"text","value":"bounded"}"#
        let exact = base + String(repeating: " ", count: IslandNode.Limits.maxJSONBytes - base.utf8.count)
        XCTAssertEqual(exact.utf8.count, IslandNode.Limits.maxJSONBytes)
        XCTAssertNoThrow(try SuperIslandViewConverter.convertJSON(exact))
        assertError(.quotaExceeded) { try SuperIslandViewConverter.convertJSON(exact + " ") }
    }

    func testActionReferencesStayDataOnlyAndDeduplicateAcrossButtonLabels() throws {
        let result = try SuperIslandViewConverter.convert(.object([
            "type": .string("hstack"), "children": .array([
                button("open"), button("open"), button("refresh")
            ])
        ]))
        XCTAssertEqual(result.actionIDs, ["open", "refresh"])
        XCTAssertEqual(PluginIslandNodeConverter.actionIDs(in: result.node), result.actionIDs)
        XCTAssertTrue(result.node.countdownReferences.isEmpty)
    }

    private func text(_ value: String) -> PluginBridgeJSON {
        .object(["type": .string("text"), "value": .string(value)])
    }

    private func icon(_ name: String) -> PluginBridgeJSON {
        .object(["type": .string("icon"), "name": .string(name)])
    }

    private func button(_ action: String) -> PluginBridgeJSON {
        .object(["type": .string("button"), "action": .string(action), "label": text("Open")])
    }

    private func progress(_ amount: Double, total: Double? = nil) -> PluginBridgeJSON {
        var fields: [String: PluginBridgeJSON] = ["type": .string("progress"), "value": .number(amount)]
        if let total { fields["total"] = .number(total) }
        return .object(fields)
    }

    private func nested(_ leaf: PluginBridgeJSON, depth: Int) -> PluginBridgeJSON {
        var result = leaf
        for _ in 1..<depth { result = .object(["type": .string("hstack"), "children": .array([result])]) }
        return result
    }

    private func countedTree(nodes: Int) -> PluginBridgeJSON {
        var remaining = nodes - 1
        var groups: [PluginBridgeJSON] = []
        while remaining > 0 {
            let children = min(16, remaining - 1)
            groups.append(.object(["type": .string("hstack"),
                "children": .array(Array(repeating: text(""), count: children))]))
            remaining -= children + 1
        }
        return .object(["type": .string("hstack"), "children": .array(groups)])
    }

    private func assertError(_ expected: SuperIslandViewConversionError,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ operation: () throws -> SuperIslandViewConverter.Conversion) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? SuperIslandViewConversionError, expected, file: file, line: line)
        }
    }
}
