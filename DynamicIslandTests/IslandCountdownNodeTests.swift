import Foundation
import XCTest
@testable import DynamicIsland

final class IslandCountdownNodeTests: XCTestCase {
    private let generation = "12345678-1234-1234-1234-123456789abc"

    func testDefaultCountdownIsTaggedAndRoundTripsWithoutBusinessState() throws {
        let reference = IslandNode.Countdown(id: "focus", generation: generation)
        let node: IslandNode = .countdown(reference)
        let data = try node.encodeJSON()
        XCTAssertEqual(try IslandNode.decodeJSON(data), node)
        XCTAssertEqual(try convert(data), node)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["type", "id", "generation"])
        XCTAssertEqual(fields["type"] as? String, "countdown")
        XCTAssertEqual(fields["id"] as? String, "focus")
        XCTAssertEqual(fields["generation"] as? String, generation)
        XCTAssertEqual(reference.style, .time)
        XCTAssertEqual(reference.color, .accent)
        XCTAssertEqual(node.countdownReferences, [reference])
        XCTAssertTrue(PluginIslandNodeConverter.actionIDs(in: node).isEmpty)
    }

    func testEveryFiniteStyleAndColorRoundTripsInNodeAndDirectCodable() throws {
        for style in IslandCountdownStyleToken.allCases {
            for color in IslandSemanticColorToken.allCases {
                let reference = IslandNode.Countdown(id: "focus-1._", generation: generation, style: style, color: color)
                let node: IslandNode = .countdown(reference)
                let nodeData = try node.encodeJSON()
                XCTAssertEqual(try IslandNode.decodeJSON(nodeData), node)
                XCTAssertEqual(try convert(nodeData), node)
                let directData = try JSONEncoder().encode(reference)
                XCTAssertEqual(try JSONDecoder().decode(IslandNode.Countdown.self, from: directData), reference)
            }
        }
        let direct = Data("{\"id\":\"focus\",\"generation\":\"\(generation)\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(IslandNode.Countdown.self, from: direct),
                       .init(id: "focus", generation: generation))
    }

    func testLocalIDBoundsAndAlphabetAreIndependentOfActionIdentifierRules() throws {
        let maximum = String(repeating: "a", count: 80)
        let valid: IslandNode = .countdown(.init(id: maximum, generation: generation))
        XCTAssertNoThrow(try valid.validate())
        XCTAssertEqual(try convert(valid.encodeJSON()), valid)
        for id in ["", "focus:timer", "../focus", "focus/timer", "focus timer", "计时", "focus\n", String(repeating: "a", count: 81)] {
            let reference = IslandNode.Countdown(id: id, generation: generation)
            let node: IslandNode = .countdown(reference)
            XCTAssertThrowsError(try node.validate()) {
                XCTAssertEqual($0 as? IslandNode.ValidationError, .invalidIdentifier)
            }
            XCTAssertThrowsError(try JSONEncoder().encode(reference))
            XCTAssertThrowsError(try node.encodeJSON())
            let data = try wire(id: id)
            XCTAssertThrowsError(try IslandNode.decodeJSON(data), id)
            XCTAssertThrowsError(try convert(data), id)
        }
        // Ordinary action IDs keep their preexisting Core vocabulary.
        XCTAssertNoThrow(try IslandNode.button(.init(actionID: "action:existing", label: .text(.init("Run")))).validate())
    }

    func testGenerationRequiresCanonicalLowercaseUUIDAtEveryBoundary() throws {
        for invalid in ["", generation.uppercased(), generation.replacingOccurrences(of: "-", with: ""),
                        "{\(generation)}", " \(generation)", "12345678-1234-1234-1234-123456789abg",
                        String(repeating: "a", count: 80)] {
            let reference = IslandNode.Countdown(id: "focus", generation: invalid)
            XCTAssertThrowsError(try IslandNode.countdown(reference).validate())
            XCTAssertThrowsError(try JSONEncoder().encode(reference))
            XCTAssertThrowsError(try IslandNode.decodeJSON(wire(generation: invalid)))
            XCTAssertThrowsError(try convert(wire(generation: invalid)))
        }
        let zero = "00000000-0000-0000-0000-000000000000"
        let node: IslandNode = .countdown(.init(id: "focus", generation: zero))
        XCTAssertEqual(try IslandNode.decodeJSON(node.encodeJSON()), node)
    }

    func testMissingWronglyTypedOrUnknownTokensRejectInsteadOfDefaulting() throws {
        var invalid: [[String: Any]] = []
        for key in ["id", "generation"] {
            var fields = base(); fields.removeValue(forKey: key); invalid.append(fields)
            for value: Any in [NSNull(), true, 1, [], ["value": "focus"]] {
                fields = base(); fields[key] = value; invalid.append(fields)
            }
        }
        for key in ["style", "color"] {
            for value: Any in [NSNull(), true, 1, [], ["value": "time"], "", "unknown"] {
                var fields = base(); fields[key] = value; invalid.append(fields)
            }
        }
        for fields in invalid {
            let data = try JSONSerialization.data(withJSONObject: fields)
            XCTAssertThrowsError(try IslandNode.decodeJSON(data))
            XCTAssertThrowsError(try convert(data))
            var direct = fields; direct.removeValue(forKey: "type")
            XCTAssertThrowsError(try JSONDecoder().decode(IslandNode.Countdown.self,
                                                        from: JSONSerialization.data(withJSONObject: direct)))
        }
    }

    func testCountdownRejectsForeignKeysIncludingKeysUsedByOtherNodeKinds() throws {
        for foreign in ["owner", "pluginID", "source", "path", "deadline", "durationMs", "remainingMs",
                        "value", "actionID", "children", "label", "width", "format"] {
            var fields = base(); fields[foreign] = "foreign"
            let data = try JSONSerialization.data(withJSONObject: fields)
            XCTAssertThrowsError(try IslandNode.decodeJSON(data), foreign)
            XCTAssertThrowsError(try convert(data), foreign)
            fields.removeValue(forKey: "type")
            XCTAssertThrowsError(try JSONDecoder().decode(IslandNode.Countdown.self,
                                                        from: JSONSerialization.data(withJSONObject: fields)), foreign)
        }
    }

    func testTimeIsMinimalAndBothStylesAreVisibleSingleRows() {
        let time = countdown()
        let progress = countdown(style: .progress)
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(time, for: .minimal))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(progress, for: .minimal))
        for node in [time, progress] {
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: .compact))
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(node, for: .expanded))
            XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(.hStack(.init([.icon(.init("timer")), node])), for: .compact))
        }
        let rows: IslandNode = .vStack(.init([time, progress]))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(rows, for: .compact))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(rows, for: .expanded))
        let presentation = ActivityPresentation(title: "Focus", minimal: time, compact: progress)
        XCTAssertEqual(presentation.resolvedNode(for: .minimal), time)
        XCTAssertEqual(presentation.resolvedNode(for: .compact), progress)
    }

    func testTimeChargesEightCharactersAndNeverChargesItsMetadataAsDisplayText() {
        let maximumID = String(repeating: "a", count: 80)
        let time = countdown(id: maximumID)
        let progress = countdown(id: maximumID, style: .progress)
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(time, for: .minimal))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(.hStack(.init([.text(.init(String(repeating: "x", count: 88))), time])), for: .compact))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(.hStack(.init([.text(.init(String(repeating: "x", count: 89))), time])), for: .compact))
        XCTAssertTrue(ActivityPresentation.HostPolicy.accepts(.hStack(.init([.text(.init(String(repeating: "x", count: 96))), progress])), for: .compact))
        XCTAssertFalse(ActivityPresentation.HostPolicy.accepts(.hStack(.init([.text(.init(String(repeating: "x", count: 97))), progress])), for: .compact))
    }

    func testReferenceTraversalIncludesButtonLabelsInAuthoredOrderWithoutInventingActions() throws {
        let first = IslandNode.Countdown(id: "focus", generation: generation)
        let second = IslandNode.Countdown(id: "pause", generation: generation, style: .progress)
        let third = IslandNode.Countdown(id: "other", generation: generation)
        let tree: IslandNode = .zStack(.init([
            .hStack(.init([
                .countdown(first),
                .button(.init(actionID: "run", label: .vStack(.init([
                    .text(.init("Status")), .countdown(second),
                    .button(.init(actionID: "stop", label: .countdown(first)))
                ]))))
            ])), .countdown(third)
        ]))
        try tree.validate()
        XCTAssertEqual(tree.countdownReferences, [first, second, first, third])
        XCTAssertEqual(PluginIslandNodeConverter.countdownNodes(in: tree), tree.countdownReferences)
        XCTAssertEqual(PluginIslandNodeConverter.actionIDs(in: tree), ["run", "stop"])
        XCTAssertEqual(try convert(tree.encodeJSON()), tree)
    }

    func testMaximumButtonLabelDepthWorksAndOverDepthProducesNoPartialReferences() throws {
        var valid = countdown()
        var wire: PluginBridgeJSON = .object([
            "type": .string("countdown"), "id": .string("focus"), "generation": .string(generation)
        ])
        for level in 1..<IslandNode.Limits.maxDepth {
            valid = .button(.init(actionID: "run\(level)", label: valid))
            wire = .object(["type": .string("button"), "actionID": .string("run\(level)"), "label": wire])
        }
        XCTAssertEqual(valid.countdownReferences.count, 1)
        XCTAssertEqual(try IslandNode.decodeJSON(valid.encodeJSON()), valid)
        XCTAssertEqual(try PluginIslandNodeConverter.parse(wire), valid)
        let excessive: IslandNode = .button(.init(actionID: "over", label: valid))
        XCTAssertTrue(excessive.countdownReferences.isEmpty)
        XCTAssertTrue(PluginIslandNodeConverter.countdownNodes(in: excessive).isEmpty)
        XCTAssertThrowsError(try excessive.validate())
        let excessiveWire = PluginBridgeJSON.object(["type": .string("button"), "actionID": .string("over"), "label": wire])
        XCTAssertThrowsError(try PluginIslandNodeConverter.parse(excessiveWire)) {
            XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded)
        }
        XCTAssertThrowsError(try IslandNode.decodeJSON(excessiveWire.encodedData()))
    }

    func testReferenceInventoryFailsClosedForChildNodeAndReferenceValidationLimits() throws {
        let leaf = countdown()
        let tooWide: IslandNode = .hStack(.init(Array(repeating: leaf, count: IslandNode.Limits.maxChildren + 1)))
        let branch = IslandNode.vStack(.init(Array(repeating: leaf, count: 16)))
        let tooMany: IslandNode = .zStack(.init(Array(repeating: branch, count: 8)))
        let malformed: IslandNode = .hStack(.init([leaf, .countdown(.init(id: "focus:other", generation: generation))]))
        for tree in [tooWide, tooMany, malformed] {
            XCTAssertThrowsError(try tree.validate())
            XCTAssertTrue(tree.countdownReferences.isEmpty)
            XCTAssertTrue(PluginIslandNodeConverter.countdownNodes(in: tree).isEmpty)
        }
        let leafWire: PluginBridgeJSON = .object([
            "type": .string("countdown"), "id": .string("focus"), "generation": .string(generation)
        ])
        let branchWire: PluginBridgeJSON = .object(["type": .string("vStack"), "children": .array(Array(repeating: leafWire, count: 16))])
        for value: PluginBridgeJSON in [
            .object(["type": .string("hStack"), "children": .array(Array(repeating: leafWire, count: 17))]),
            .object(["type": .string("zStack"), "children": .array(Array(repeating: branchWire, count: 8))])
        ] {
            XCTAssertThrowsError(try PluginIslandNodeConverter.parse(value)) {
                XCTAssertEqual($0 as? PluginBridgeErrorCode, .quotaExceeded)
            }
        }
    }

    private func countdown(id: String = "focus", style: IslandCountdownStyleToken = .time) -> IslandNode {
        .countdown(.init(id: id, generation: generation, style: style))
    }

    private func base() -> [String: Any] {
        ["type": "countdown", "id": "focus", "generation": generation]
    }

    private func wire(id: String = "focus", generation: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "countdown", "id": id, "generation": generation ?? self.generation])
    }

    private func convert(_ data: Data) throws -> IslandNode {
        try PluginIslandNodeConverter.parse(PluginBridgeJSON.parse(String(decoding: data, as: UTF8.self), maximumBytes: IslandNode.Limits.maxJSONBytes))
    }
}
