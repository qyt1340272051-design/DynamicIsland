import Foundation
import XCTest
@testable import DynamicIsland

final class IslandNodeTests: XCTestCase {
    func testTimerBuildAndMusicSummariesRoundTrip() throws {
        let timer: IslandNode = .vStack(.init([
            .hStack(.init([
                .icon(.init("timer")),
                .text(.init("Focus 24:58")),
                .spacer(.init()),
                .button(.init(actionID: "timer.pause", label: .icon(.init("pause.fill"))))
            ])),
            .progress(.init(0.42))
        ]))
        let build: IslandNode = .vStack(.init([
            .hStack(.init([.icon(.init("hammer.fill")), .text(.init("Building"))])),
            .progress(.init(0.7)),
            .text(.init("Target: Dynamic Island"))
        ]))
        let music: IslandNode = .hStack(.init([
            .image(.init(source: .brokerResource(id: "artwork.current"))),
            .vStack(.init([.text(.init("Track")), .text(.init("Artist"))])),
            .spacer(.init()),
            .button(.init(actionID: "music.playPause", label: .icon(.init("play.fill"))))
        ]))

        for tree in [timer, build, music] {
            try tree.validate()
            let data = try tree.encodeJSON()
            XCTAssertEqual(try IslandNode.decodeJSON(data), tree)
            XCTAssertEqual(try JSONDecoder().decode(IslandNode.self, from: data), tree)
        }
    }

    func testAllNodeKindsAndImageSourcesAreTaggedAndCodable() throws {
        let tree: IslandNode = .zStack(.init([
            .image(.init(source: .systemSymbol(name: "music.note"))),
            .image(.init(source: .pluginAsset(id: "cover.default"))),
            .divider(.init()),
            .toggle(.init(title: "Alerts", isOn: true, actionID: "alerts.toggle")),
            .slider(.init(title: "Volume", value: 0.75, actionID: "volume.set"))
        ]))
        let data = try tree.encodeJSON()
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"type\":\"zStack\""))
        XCTAssertTrue(json.contains("\"type\":\"systemSymbol\""))
        XCTAssertTrue(json.contains("\"type\":\"pluginAsset\""))
        XCTAssertEqual(try IslandNode.decodeJSON(data), tree)
    }

    func testImageSizeAndSliderTitleDecodeLegacyJSON() throws {
        let oldImage = Data(#"{"type":"image","source":{"type":"brokerResource","id":"artwork.current"}}"#.utf8)
        XCTAssertEqual(
            try IslandNode.decodeJSON(oldImage),
            .image(.init(source: .brokerResource(id: "artwork.current"), size: .icon))
        )
        let directImage = Data(#"{"source":{"type":"pluginAsset","id":"cover"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(IslandNode.Image.self, from: directImage).size, .icon)

        let artwork: IslandNode = .image(.init(source: .brokerResource(id: "artwork.current"), size: .artwork))
        let artworkJSON = try artwork.encodeJSON()
        XCTAssertEqual(try IslandNode.decodeJSON(artworkJSON), artwork)
        XCTAssertTrue(String(decoding: artworkJSON, as: UTF8.self).contains(#""size":"artwork""#))
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data(
            #"{"type":"image","source":{"type":"pluginAsset","id":"cover"},"size":"999pt"}"#.utf8
        )))
        let thumbnail: IslandNode = .image(.init(source: .brokerResource(id: "artwork.current"), size: .thumbnail))
        XCTAssertEqual(try IslandNode.decodeJSON(thumbnail.encodeJSON()), thumbnail)

        let oldSlider = Data(#"{"type":"slider","title":"Position","value":0.5,"actionID":"music.seek"}"#.utf8)
        XCTAssertEqual(try IslandNode.decodeJSON(oldSlider),
                       .slider(.init(title: "Position", value: 0.5, actionID: "music.seek", showsTitle: true)))
        let directSlider = Data(#"{"title":"Position","value":0.5,"actionID":"music.seek"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(IslandNode.Slider.self, from: directSlider).showsTitle)

        let untitled: IslandNode = .slider(.init(title: "Position", value: 0.5,
                                                actionID: "music.seek", showsTitle: false))
        let untitledJSON = try untitled.encodeJSON()
        XCTAssertEqual(try IslandNode.decodeJSON(untitledJSON), untitled)
        XCTAssertTrue(String(decoding: untitledJSON, as: UTF8.self).contains(#""showsTitle":false"#))

        let oldButton = Data(#"{"type":"button","actionID":"music.next","label":{"type":"icon","symbolName":"forward.fill"}}"#.utf8)
        XCTAssertEqual(
            try IslandNode.decodeJSON(oldButton),
            .button(.init(actionID: "music.next", label: .icon(.init("forward.fill"))))
        )
        let accessibleButton: IslandNode = .button(.init(
            actionID: "music.next",
            label: .icon(.init("forward.fill")),
            accessibilityLabel: "下一首"
        ))
        XCTAssertEqual(try IslandNode.decodeJSON(accessibleButton.encodeJSON()), accessibleButton)
    }

    func testRejectsUnknownAndMalformedNodes() {
        for json in [
            #"{"type":"webView","url":"https://example.com"}"#,
            #"{"type":"text"}"#,
            #"{"type":"progress","value":"half"}"#,
            #"{"type":"image","source":{"type":"remoteURL","url":"https://example.com/a.png"}}"#,
            #"{"type":"hStack","children":{}}"#
        ] {
            XCTAssertThrowsError(try IslandNode.decodeJSON(Data(json.utf8)), json)
        }
    }

    func testRejectsUnsafeIdentifiersAndNonFiniteOrOutOfRangeNumbers() {
        for id in ["", "../private", "https://example.com", "a/b", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try IslandNode.button(.init(actionID: id, label: .text(.init("OK")))).validate())
        }
        XCTAssertThrowsError(try IslandNode.image(.init(source: .pluginAsset(id: "../secret"))).validate())
        XCTAssertThrowsError(try IslandNode.image(.init(source: .brokerResource(id: "https://example.com"))).validate())
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try IslandNode.progress(.init(value)).validate())
            XCTAssertThrowsError(try IslandNode.slider(.init(title: "Volume", value: value, actionID: "volume.set")).validate())
        }
    }

    func testRejectsTreeAndStringLimitsOnConstructionAndDecode() throws {
        let tooManyChildren = IslandNode.hStack(.init(
            Array(repeating: .spacer(.init()), count: IslandNode.Limits.maxChildren + 1)
        ))
        XCTAssertThrowsError(try tooManyChildren.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(tooManyChildren))

        let tooLongText = IslandNode.text(.init(String(repeating: "好", count: IslandNode.Limits.maxTextBytes)))
        XCTAssertThrowsError(try tooLongText.validate())
        let longTextJSON = #"{"type":"text","content":""#
            + String(repeating: "x", count: IslandNode.Limits.maxTextBytes + 1) + #""}"#
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data(longTextJSON.utf8)))

        var deep: IslandNode = .text(.init("bottom"))
        for _ in 0..<IslandNode.Limits.maxDepth { deep = .vStack(.init([deep])) }
        XCTAssertThrowsError(try deep.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(deep))

        let branch: IslandNode = .vStack(.init(Array(repeating: .spacer(.init()), count: 16)))
        let tooManyNodes: IslandNode = .vStack(.init(Array(repeating: branch, count: 8)))
        XCTAssertThrowsError(try tooManyNodes.validate())
        let spacerJSON = #"{"type":"spacer"}"#
        let branchJSON = #"{"type":"vStack","children":["#
            + Array(repeating: spacerJSON, count: 16).joined(separator: ",") + "]}"
        let overBudgetJSON = #"{"type":"vStack","children":["#
            + Array(repeating: branchJSON, count: 8).joined(separator: ",") + "]}"
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data(overBudgetJSON.utf8)))
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data(repeating: 32, count: IslandNode.Limits.maxJSONBytes + 1)))
    }

    func testDecoderEnforcesDepthAndChildrenBeforeRendering() throws {
        var json = #"{"type":"text","content":"ok"}"#
        for _ in 0..<IslandNode.Limits.maxDepth {
            json = #"{"type":"vStack","children":["# + json + "]}"
        }
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data(json.utf8)))

        let children = Array(repeating: #"{"type":"spacer"}"#, count: IslandNode.Limits.maxChildren + 1)
            .joined(separator: ",")
        XCTAssertThrowsError(try IslandNode.decodeJSON(Data((#"{"type":"hStack","children":["# + children + "]}").utf8)))
    }
}
