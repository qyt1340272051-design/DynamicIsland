import Foundation
import XCTest

final class PluginDocumentRegistrationTests: XCTestCase {
    func testBuiltHostExportsDIPForFinderDeliveryWithoutClaimingGenericZIP() throws {
        let identifier = "com.rong5.dynamic-island.plugin"
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let exported = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let type = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == identifier })
        let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["dip"])
        XCTAssertTrue((type["UTTypeConformsTo"] as? [String])?.contains("public.zip-archive") == true)
        let documents = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try XCTUnwrap(documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(identifier) == true })
        XCTAssertEqual(document["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(document["LSHandlerRank"] as? String, "Owner")
        XCTAssertFalse(documents.contains { ($0["LSItemContentTypes"] as? [String])?.contains("public.zip-archive") == true })
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
    }
}
