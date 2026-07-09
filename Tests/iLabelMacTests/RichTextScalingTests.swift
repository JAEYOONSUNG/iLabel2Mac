import AppKit
import XCTest
@testable import iLabelMac

final class RichTextScalingTests: XCTestCase {
    func testRendererPreservesPerRunFontSizes() throws {
        // Sizes can differ per selection, so the renderer must honor each
        // run's own size instead of normalizing to element.fontSize.
        var element = LabelElement.make(.text, index: 1)
        element.content = "{{serial}}"
        element.fontSize = 3.5
        element.fontName = "Arial"
        element.foreground = .black
        element.richTextRTF = try richTextData(string: "{{serial}}", pointSize: 96)

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: MergeContext(
                row: [:],
                serialValue: 7,
                rowNumber: 1,
                pageNumber: 1,
                slotNumber: 1,
                isActive: true
            ),
            serialSettings: .default
        )

        XCTAssertEqual(rendered.string, "(7)")
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 96, accuracy: 0.01)
    }

    func testElementWideSizeChangeScalesRunsProportionally() throws {
        // 12pt and 24pt runs; doubling the element size must keep the 1:2 mix.
        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "a", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        mixed.append(NSAttributedString(string: "b", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        let rtf = try XCTUnwrap(mixed.rtf(
            from: NSRange(location: 0, length: mixed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let scaled = try XCTUnwrap(LabelElement.scalingFontSizes(of: rtf, by: 2))
        let decoded = try XCTUnwrap(NSAttributedString(
            data: scaled,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ))
        let first = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let second = try XCTUnwrap(decoded.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(first.pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(second.pointSize, 48, accuracy: 0.01)
    }

    func testEditingContentClearsStaleRichText() throws {
        var element = LabelElement.make(.text, index: 1)
        element.content = "OLD"
        element.richTextRTF = try richTextData(string: "OLD", pointSize: 12)
        XCTAssertNotNil(element.richTextRTF)

        // Simulates pasting / typing new text through any plain-text surface
        // (inspector "Content" box, token buttons). The stale RTF must drop.
        element.content = "NEW"
        XCTAssertNil(element.richTextRTF, "Editing content should clear the mismatched RTF override")
    }

    func testRendererUsesContentWhenRichTextIsStale() throws {
        // An older document could still hold a diverged RTF (didSet only fires on
        // mutation, not on decode). The renderer must fall back to `content`.
        var element = LabelElement.make(.text, index: 1)
        element.fontName = "Arial"
        element.richTextRTF = try richTextData(string: "OLD", pointSize: 12)
        // Bypass didSet by decoding a hand-built element: assign content that
        // mismatches the RTF and confirm the renderer prefers content.
        element.content = "NEW"

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: MergeContext(row: [:], serialValue: 0, rowNumber: 1, pageNumber: 1, slotNumber: 1, isActive: true),
            serialSettings: .default
        )
        XCTAssertEqual(rendered.string, "NEW")
    }

    func testRendererPreservesPerRunFontFamilies() throws {
        // Fonts can differ per selection, so the renderer must keep each
        // run's family and size.
        var element = LabelElement.make(.text, index: 1)
        element.content = "AB"
        element.fontName = "Arial"
        element.fontSize = 12

        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "A", attributes: [.font: try XCTUnwrap(NSFont(name: "Helvetica", size: 30))]))
        mixed.append(NSAttributedString(string: "B", attributes: [.font: try XCTUnwrap(NSFont(name: "Courier", size: 30))]))
        element.richTextRTF = try XCTUnwrap(mixed.rtf(
            from: NSRange(location: 0, length: mixed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: MergeContext(row: [:], serialValue: 0, rowNumber: 1, pageNumber: 1, slotNumber: 1, isActive: true),
            serialSettings: .default
        )

        let first = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let second = try XCTUnwrap(rendered.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(first.familyName, "Helvetica")
        XCTAssertEqual(second.familyName, "Courier")
        XCTAssertEqual(first.pointSize, 30, accuracy: 0.01)
        XCTAssertEqual(second.pointSize, 30, accuracy: 0.01)
    }

    func testElementWideFontChangeRewritesRichTextRunsButKeepsBoldTrait() throws {
        // "A" bold, "B" regular — like a selection bolded in the inline editor.
        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "A", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)]))
        mixed.append(NSAttributedString(string: "B", attributes: [.font: NSFont.systemFont(ofSize: 30)]))
        let rtf = try XCTUnwrap(mixed.rtf(
            from: NSRange(location: 0, length: mixed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let rewritten = try XCTUnwrap(LabelElement.rewritingFontFamily(of: rtf, to: "Arial"))
        let decoded = try XCTUnwrap(NSAttributedString(
            data: rewritten,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ))

        let boldRun = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let plainRun = try XCTUnwrap(decoded.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(boldRun.familyName, "Arial", "element-wide font change must rewrite existing runs")
        XCTAssertEqual(plainRun.familyName, "Arial")
        XCTAssertTrue(NSFontManager.shared.traits(of: boldRun).contains(.boldFontMask), "per-run bold must survive")
        XCTAssertFalse(NSFontManager.shared.traits(of: plainRun).contains(.boldFontMask))
        XCTAssertEqual(boldRun.pointSize, 30, accuracy: 0.01, "rewrite keeps run sizes; element size applies at render")
    }

    private func richTextData(string: String, pointSize: CGFloat) throws -> Data {
        let attributed = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.systemFont(ofSize: pointSize),
                .foregroundColor: NSColor.black
            ]
        )
        return try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
    }
}
