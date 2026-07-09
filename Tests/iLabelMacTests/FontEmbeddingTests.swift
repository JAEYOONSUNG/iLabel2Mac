import AppKit
import XCTest
@testable import iLabelMac

final class FontEmbeddingTests: XCTestCase {
    func testSystemFontsAreNotEmbedded() {
        var doc = LabelDocument.starter
        for i in doc.elements.indices where doc.elements[i].type == .text {
            doc.elements[i].fontName = "Helvetica" // ships under /System on every Mac
            doc.elements[i].richTextRTF = nil
        }
        XCTAssertTrue(
            FontEmbedder.collect(from: doc).isEmpty,
            "Fonts under /System are present on all Macs and must never be embedded"
        )
    }

    func testDocumentIsBackwardCompatibleWithoutEmbeddedFonts() throws {
        // A project saved before font embedding existed has no `embeddedFonts`
        // key. Encoding starter (embeddedFonts == nil) omits the key, so this
        // round-trip stands in for opening an older file.
        let data = try JSONEncoder().encode(LabelDocument.starter)
        XCTAssertFalse(
            String(data: data, encoding: .utf8)?.contains("embeddedFonts") ?? true,
            "A nil embeddedFonts should be omitted, matching older project files"
        )
        let decoded = try JSONDecoder().decode(LabelDocument.self, from: data)
        XCTAssertNil(decoded.embeddedFonts)
    }

    func testRealCustomFontEmbedsAndSurvivesSaveLoad() throws {
        // Find an actual non-system font installed on this machine.
        let manager = NSFontManager.shared
        let customFamily = manager.availableFontFamilies.first { family -> Bool in
            guard let font = NSFont(name: family, size: 12)
                ?? manager.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            guard let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL else { return false }
            return !url.path.hasPrefix("/System/")
        }
        guard let customFamily else {
            throw XCTSkip("No non-system font installed on this machine to test embedding")
        }

        var doc = LabelDocument.starter
        var element = LabelElement.make(.text, index: 1)
        element.fontName = customFamily
        element.richTextRTF = nil
        doc.elements = [element]

        // Collect → must embed the custom font with real bytes.
        let collected = FontEmbedder.collect(from: doc)
        XCTAssertFalse(collected.isEmpty, "Custom font \(customFamily) should be embedded")
        XCTAssertGreaterThan(collected.first?.data.count ?? 0, 100, "Embedded font data should be the real file")

        // Save → JSON must carry the embedded font; Load → decodes back.
        var toSave = doc
        toSave.embeddedFonts = collected
        let json = try JSONEncoder().encode(toSave)
        XCTAssertTrue(String(data: json, encoding: .utf8)?.contains("embeddedFonts") ?? false)
        let decoded = try JSONDecoder().decode(LabelDocument.self, from: json)
        XCTAssertEqual(decoded.embeddedFonts?.count, collected.count)

        // Registration must not crash and leaves the font resolvable.
        FontEmbedder.register(decoded.embeddedFonts)
        XCTAssertNotNil(NSFont(name: collected.first!.postScriptName, size: 12))
    }

    func testEmbeddedFontRoundTrips() throws {
        let original = EmbeddedFont(postScriptName: "Foo-Bold", familyName: "Foo", data: Data([1, 2, 3, 4]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EmbeddedFont.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
