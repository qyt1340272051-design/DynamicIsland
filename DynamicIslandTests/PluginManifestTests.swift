import Foundation
import XCTest
@testable import DynamicIsland

final class PluginManifestTests: XCTestCase {
    private let requiredFields: Set<String> = [
        "schemaVersion", "id", "name", "version", "engine", "entry",
        "minimumHostVersion", "permissions", "capabilities"
    ]

    func testDecodesCompleteAndMinimalV1Manifests() throws {
        let manifest = try PluginManifest.decodeJSON(try fixtureData())

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.id, "com.example.focus-timer")
        XCTAssertEqual(manifest.name, "Focus Timer")
        XCTAssertEqual(manifest.version.description, "1.2.3-beta.1+build.7")
        XCTAssertEqual(manifest.engine, .javaScriptCore)
        XCTAssertEqual(manifest.entry, "src/index.js")
        XCTAssertEqual(manifest.minimumHostVersion.description, "0.6.0")
        XCTAssertEqual(manifest.permissions, [.network, .localStorage])
        XCTAssertEqual(manifest.capabilities, [.publishActivity, .islandNodeUI, .handleActions])

        let minimal = try PluginManifest.decodeJSON(try fixtureData {
            $0["permissions"] = []
            $0["capabilities"] = []
        })
        XCTAssertTrue(minimal.permissions.isEmpty)
        XCTAssertTrue(minimal.capabilities.isEmpty)
    }

    func testCodableRoundTripPreservesAllNineFields() throws {
        let original = try PluginManifest.decodeJSON(try fixtureData())
        let encoded = try original.encodeJSON(prettyPrinted: true)
        let decoded = try PluginManifest.decodeJSON(encoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(Set(object.keys), requiredFields)
        XCTAssertEqual(object["version"] as? String, "1.2.3-beta.1+build.7")
    }

    func testRejectsMalformedJSONWrongRootAndOversizeInput() {
        for data in [Data("{".utf8), Data("[]".utf8), Data("null".utf8), Data(#""text""#.utf8)] {
            assertManifestError(data, code: "malformedJSON", path: "$")
        }
        assertManifestError(
            Data(repeating: 32, count: PluginManifest.Limits.maxJSONBytes + 1),
            code: "jsonTooLarge",
            path: "$"
        )
    }

    func testUnknownTopLevelFieldsFailThroughBothDecodeEntryPoints() throws {
        let data = try fixtureData { $0["publisherVerified"] = true }
        assertManifestError(data, code: "unknownField", path: "$.publisherVerified")

        XCTAssertThrowsError(try JSONDecoder().decode(PluginManifest.self, from: data)) { error in
            XCTAssertEqual(error as? PluginManifestError, .unknownField("publisherVerified"))
        }
    }

    func testOptionalDeveloperIsStrictDisplayMetadataAndPreservesLegacyEncoding() throws {
        let legacy = try PluginManifest.decodeJSON(try fixtureData())
        XCTAssertNil(legacy.developer)
        let manifest = try PluginManifest.decodeJSON(try fixtureData { $0["developer"] = "Example 开发者" })
        XCTAssertEqual(manifest.developer, "Example 开发者")
        XCTAssertEqual(try PluginManifest.decodeJSON(manifest.encodeJSON()), manifest)
        for text in ["", " leading", "trailing ", "bad\nname", "spoof\u{202E}publisher", String(repeating: "x", count: 81)] {
            assertManifestError(try fixtureData { $0["developer"] = text }, code: "invalidDeveloper", path: "$.developer")
        }
        for value: Any in [NSNull(), 1, ["name": "Example"]] {
            assertManifestError(try fixtureData { $0["developer"] = value }, code: "invalidType", path: "$.developer")
        }
    }

    func testUntrustedDecodeBoundaryRejectsDuplicateTopLevelFields() throws {
        let base = try XCTUnwrap(String(data: fixtureData(), encoding: .utf8))
        let withoutClosingBrace = String(base.dropLast())
        let duplicateID = withoutClosingBrace + #", "id": "com.example.replacement"}"#
        for (field, suffix) in [
            ("id", #", "id": "com.example.replacement"}"#),
            ("permissions", #", "permissions": []}"#),
            ("id", #", "\u0069d": "com.example.escaped"}"#)
        ] {
            assertManifestError(
                Data((withoutClosingBrace + suffix).utf8),
                code: "duplicateField",
                path: "$.\(field)"
            )
        }

        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(Data(duplicateID.utf8))
        for encoded in [
            utf8BOM,
            try XCTUnwrap(duplicateID.data(using: .utf16)),
            try XCTUnwrap(duplicateID.data(using: .utf16LittleEndian)),
            try XCTUnwrap(duplicateID.data(using: .utf16BigEndian))
        ] {
            assertManifestError(encoded, code: "malformedJSON", path: "$")
        }
    }

    func testEveryFieldIsRequired() throws {
        for field in requiredFields {
            let data = try fixtureData { $0.removeValue(forKey: field) }
            assertManifestError(data, code: "missingField", path: "$.\(field)")
        }
    }

    func testSchemaVersionAndFieldTypesAreStrict() throws {
        for version in [0, 2, -1] {
            assertManifestError(
                try fixtureData { $0["schemaVersion"] = version },
                code: "unsupportedSchemaVersion",
                path: "$.schemaVersion"
            )
        }
        assertManifestError(
            try fixtureData { $0["schemaVersion"] = "1" },
            code: "invalidType",
            path: "$.schemaVersion"
        )
        assertManifestError(
            try fixtureData { $0["permissions"] = "network" },
            code: "invalidType",
            path: "$.permissions"
        )
    }

    func testPluginIdentifierRule() throws {
        for value in [
            "com.example.timer", "io.rong5.timer-2", "dev.example2.focus.timer"
        ] {
            XCTAssertTrue(PluginManifest.isValidPluginID(value), value)
            XCTAssertNoThrow(try PluginManifest.decodeJSON(try fixtureData { $0["id"] = value }), value)
        }

        let longSegment = String(repeating: "a", count: PluginManifest.Limits.maxPluginIDSegmentBytes + 1)
        let longID = "com.example." + String(repeating: "a", count: PluginManifest.Limits.maxPluginIDBytes)
        for value in [
            "", "example.timer", "Com.example.timer", "com..timer", "com.example.-timer",
            "com.example.timer-", "1com.example.timer", "com.example.time_r", "com/example/timer",
            "com.example.计时", "com.example.\(longSegment)", longID
        ] {
            XCTAssertFalse(PluginManifest.isValidPluginID(value), value)
            assertManifestError(
                try fixtureData { $0["id"] = value },
                code: "invalidPluginID",
                path: "$.id"
            )
        }
    }

    func testSemanticVersionParsingAndOfficialPrecedenceChain() throws {
        for value in [
            "0.0.0", "1.2.3", "1.2.3-alpha.1+build.5",
            "184467440737095516160.2.3"
        ] {
            XCTAssertEqual(try SemanticVersion(value).description, value)
        }
        for value in [
            "", "1", "1.2", "v1.2.3", "01.2.3", "1.02.3", "1.2.03",
            "1.2.3-", "1.2.3+", "1.2.3-alpha..1", "1.2.3-01", "1.2.3-ä"
        ] {
            XCTAssertThrowsError(try SemanticVersion(value), value)
        }

        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"
        ]
        for pair in zip(ordered, ordered.dropFirst()) {
            let lower = try SemanticVersion(pair.0)
            let higher = try SemanticVersion(pair.1)
            XCTAssertEqual(lower.precedence(comparedTo: higher), .orderedAscending)
            XCTAssertTrue(higher.isAtLeast(lower))
        }

        let build1 = try SemanticVersion("1.0.0+build.1")
        let build2 = try SemanticVersion("1.0.0+build.2")
        XCTAssertNotEqual(build1, build2, "Build metadata remains part of value identity")
        XCTAssertEqual(build1.precedence(comparedTo: build2), .orderedSame)
    }

    func testManifestRejectsInvalidVersionsAtExactPaths() throws {
        assertManifestError(
            try fixtureData { $0["version"] = "1.2" },
            code: "invalidSemanticVersion",
            path: "$.version"
        )
        assertManifestError(
            try fixtureData { $0["minimumHostVersion"] = "v0.6.0" },
            code: "invalidSemanticVersion",
            path: "$.minimumHostVersion"
        )
    }

    func testOnlyExplicitRuntimeProfilesAreAcceptedAndRoundTrip() throws {
        for engine in PluginEngine.allCases {
            let manifest = try PluginManifest.decodeJSON(try fixtureData { $0["engine"] = engine.rawValue })
            XCTAssertEqual(manifest.engine, engine)
            XCTAssertEqual(try PluginManifest.decodeJSON(manifest.encodeJSON()), manifest)
        }
        for value in ["javascriptCore", "JavaScriptCore", "SuperIsland", "superisland-v2", "native", ""] {
            assertManifestError(
                try fixtureData { $0["engine"] = value },
                code: "unsupportedEngine",
                path: "$.engine"
            )
        }
    }

    func testEveryRuntimeProfilePreservesStrictManifestFieldsAndDeclarations() throws {
        for engine in PluginEngine.allCases {
            assertManifestError(try fixtureData {
                $0["engine"] = engine.rawValue
                $0["compatibility"] = "superisland"
            }, code: "unknownField", path: "$.compatibility")
            assertManifestError(try fixtureData {
                $0["engine"] = engine.rawValue
                $0["permissions"] = ["filesystem"]
            }, code: "unknownPermission", path: "$.permissions[0]")
            assertManifestError(try fixtureData {
                $0["engine"] = engine.rawValue
                $0["capabilities"] = ["window.control"]
            }, code: "unknownCapability", path: "$.capabilities[0]")
            let data = try fixtureData { $0["engine"] = engine.rawValue }
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            let duplicate = Data((String(json.dropLast()) + #", "\u0065ngine": "superisland"}"#).utf8)
            assertManifestError(duplicate, code: "duplicateField", path: "$.engine")
        }
    }

    func testEntryPathIsNormalizedRelativeJavaScriptPath() throws {
        for value in ["index.js", "src/main.js", "dist/plugin_v2-1.js"] {
            XCTAssertTrue(PluginManifest.isValidEntry(value), value)
            XCTAssertNoThrow(try PluginManifest.decodeJSON(try fixtureData { $0["entry"] = value }), value)
        }
        for value in [
            "", "/index.js", "./index.js", "../index.js", "src/../index.js", "src//index.js",
            ".js", "src/.js", "src\\index.js", "src/index.mjs", "src/%2e%2e/index.js", "src:index.js",
            "src/\0index.js"
        ] {
            XCTAssertFalse(PluginManifest.isValidEntry(value), value)
            assertManifestError(
                try fixtureData { $0["entry"] = value },
                code: "invalidEntry",
                path: "$.entry"
            )
        }
    }

    func testNameRejectsWhitespaceControlCharactersAndLengthOverflow() throws {
        for value in [
            "", " Focus", "Focus ", "\u{00A0}Focus", "Focus\u{3000}", "Focus\nTimer",
            "Focus\u{180E}Timer", "Focus\u{200B}Timer", "Focus\u{2028}Timer",
            "Focus\u{FEFF}Timer", String(repeating: "a", count: 81)
        ] {
            assertManifestError(
                try fixtureData { $0["name"] = value },
                code: "invalidName",
                path: "$.name"
            )
        }
        XCTAssertNoThrow(try PluginManifest.decodeJSON(try fixtureData { $0["name"] = "专注计时" }))
    }

    func testPermissionsAndCapabilitiesAreClosedUniqueSets() throws {
        let allPermissions = PluginPermission.allCases.map(\.rawValue)
        let allCapabilities = PluginCapability.allCases.map(\.rawValue)
        let manifest = try PluginManifest.decodeJSON(try fixtureData {
            $0["permissions"] = allPermissions
            $0["capabilities"] = allCapabilities
        })
        XCTAssertEqual(manifest.permissions.map(\.rawValue), allPermissions)
        XCTAssertEqual(manifest.capabilities.map(\.rawValue), allCapabilities)
        assertManifestError(
            try fixtureData { $0["permissions"] = ["presentation.request"] },
            code: "unknownPermission", path: "$.permissions[0]"
        )

        assertManifestError(
            try fixtureData { $0["permissions"] = ["shell.execute"] },
            code: "unknownPermission",
            path: "$.permissions[0]"
        )
        assertManifestError(
            try fixtureData { $0["permissions"] = ["network", "network"] },
            code: "duplicatePermission",
            path: "$.permissions[1]"
        )
        assertManifestError(
            try fixtureData { $0["capabilities"] = ["native.view"] },
            code: "unknownCapability",
            path: "$.capabilities[0]"
        )
        assertManifestError(
            try fixtureData { $0["capabilities"] = ["scheduler", "scheduler"] },
            code: "duplicateCapability",
            path: "$.capabilities[1]"
        )
    }

    func testPublishedSchemaMatchesRuntimeContract() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let schemaURL = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/plugin-system/schema/plugin-manifest-v1.schema.json")
        let schemaData = try Data(contentsOf: schemaURL)
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])

        XCTAssertEqual(schema["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), requiredFields)
        XCTAssertEqual(Set(properties.keys), requiredFields.union(["developer"]))
        XCTAssertEqual((properties["developer"] as? [String: Any])?["$ref"] as? String, "#/properties/name")

        let schemaVersion = try XCTUnwrap(properties["schemaVersion"] as? [String: Any])
        XCTAssertEqual(schemaVersion["const"] as? Int, PluginManifest.currentSchemaVersion)
        XCTAssertEqual(try enumValues(in: properties, field: "engine"), PluginEngine.allCases.map(\.rawValue))
        XCTAssertEqual(
            try arrayEnumValues(in: properties, schema: schema, field: "permissions"),
            PluginPermission.allCases.map(\.rawValue)
        )
        XCTAssertEqual(
            try arrayEnumValues(in: properties, schema: schema, field: "capabilities"),
            PluginCapability.allCases.map(\.rawValue)
        )
        for field in ["permissions", "capabilities"] {
            let property = try XCTUnwrap(properties[field] as? [String: Any])
            XCTAssertEqual(property["uniqueItems"] as? Bool, true)
            let count = field == "permissions" ? PluginPermission.allCases.count : PluginCapability.allCases.count
            XCTAssertEqual(property["maxItems"] as? Int, count, field)
        }

        let idProperty = try XCTUnwrap(properties["id"] as? [String: Any])
        XCTAssertEqual(idProperty["maxLength"] as? Int, PluginManifest.Limits.maxPluginIDBytes)
        let idPattern = try XCTUnwrap(idProperty["pattern"] as? String)
        for value in ["com.example.timer", "io.rong5.timer-2", "1com.example.timer", "com..timer"] {
            XCTAssertEqual(matches(pattern: idPattern, value: value), PluginManifest.isValidPluginID(value), value)
        }

        let entryProperty = try XCTUnwrap(properties["entry"] as? [String: Any])
        XCTAssertEqual(entryProperty["maxLength"] as? Int, PluginManifest.Limits.maxEntryBytes)
        let entryPattern = try XCTUnwrap(entryProperty["pattern"] as? String)
        for value in ["index.js", "src/main.js", ".js", "src/.js", "../index.js", "src\\main.js"] {
            XCTAssertEqual(matches(pattern: entryPattern, value: value), PluginManifest.isValidEntry(value), value)
        }

        let nameProperty = try XCTUnwrap(properties["name"] as? [String: Any])
        XCTAssertEqual(nameProperty["maxLength"] as? Int, PluginManifest.Limits.maxNameCharacters)
        let namePattern = try XCTUnwrap(nameProperty["pattern"] as? String)
        for value in ["Focus Timer", "专注计时", " Focus", "Focus\u{200B}Timer", "Focus\u{2028}Timer"] {
            let acceptedByRuntime = (try? PluginManifest.decodeJSON(
                fixtureData { $0["name"] = value }
            )) != nil
            XCTAssertEqual(matches(pattern: namePattern, value: value), acceptedByRuntime, value)
        }

        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let semanticVersion = try XCTUnwrap(definitions["semanticVersion"] as? [String: Any])
        let semanticVersionPattern = try XCTUnwrap(semanticVersion["pattern"] as? String)
        for value in ["0.0.0", "1.2.3-alpha.1+build.5", "1.2", "1.2.03", "1.2.3-01"] {
            XCTAssertEqual(matches(pattern: semanticVersionPattern, value: value), (try? SemanticVersion(value)) != nil, value)
        }
    }

    func testOfficialExamplesFitPublishedManifestArrayLimits() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let schemaData = try Data(contentsOf: root.appendingPathComponent("docs/plugin-system/schema/plugin-manifest-v1.schema.json"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let examples = root.appendingPathComponent("docs/plugin-system/examples")
        let directories = try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil)
        var checked = 0
        for directory in directories {
            let url = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let manifest = try PluginManifest.decodeJSON(Data(contentsOf: url))
            for (field, values) in ["permissions": manifest.permissions.map(\.rawValue),
                                    "capabilities": manifest.capabilities.map(\.rawValue)] {
                let property = try XCTUnwrap(properties[field] as? [String: Any])
                XCTAssertLessThanOrEqual(values.count, try XCTUnwrap(property["maxItems"] as? Int),
                                         "\(directory.lastPathComponent): \(field)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    private func fixtureData(_ update: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "id": "com.example.focus-timer",
            "name": "Focus Timer",
            "version": "1.2.3-beta.1+build.7",
            "engine": "javascriptcore",
            "entry": "src/index.js",
            "minimumHostVersion": "0.6.0",
            "permissions": ["network", "storage.local"],
            "capabilities": ["activity.publish", "ui.islandNode", "actions.handle"]
        ]
        update?(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func assertManifestError(
        _ data: @autoclosure () throws -> Data,
        code: String,
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try PluginManifest.decodeJSON(data())
            XCTFail("Expected PluginManifestError", file: file, line: line)
        } catch let error as PluginManifestError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertEqual(error.path, path, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func enumValues(in properties: [String: Any], field: String) throws -> [String] {
        let property = try XCTUnwrap(properties[field] as? [String: Any])
        return try XCTUnwrap(property["enum"] as? [String])
    }

    private func arrayEnumValues(
        in properties: [String: Any],
        schema: [String: Any],
        field: String
    ) throws -> [String] {
        let property = try XCTUnwrap(properties[field] as? [String: Any])
        let items = try XCTUnwrap(property["items"] as? [String: Any])
        if let values = items["enum"] as? [String] { return values }
        let reference = try XCTUnwrap(items["$ref"] as? String)
        let definitionName = try XCTUnwrap(reference.split(separator: "/").last.map(String.init))
        let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let definition = try XCTUnwrap(definitions[definitionName] as? [String: Any])
        return try XCTUnwrap(definition["enum"] as? [String])
    }

    private func matches(pattern: String, value: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}
