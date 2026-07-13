import AppKit
import XCTest
@testable import iLabelMac

@MainActor
final class PasteMatchStyleTests: XCTestCase {
    private func makeEditor(typingFont: NSFont) -> MatchStylePasteTextView {
        let textView = MatchStylePasteTextView()
        textView.isRichText = true
        textView.typingAttributes = [.font: typingFont]
        return textView
    }

    private func foreignRTF(_ string: String, fontName: String, size: CGFloat) throws -> Data {
        let font = try XCTUnwrap(NSFont(name: fontName, size: size))
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        return try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
    }

    func testRichPasteboardFlavorIsDowngradedToTypingStyle() throws {
        // Foreign RTF (Times 48) must land as the editor's typing style, not
        // keep its own font runs — stored foreign runs make the element-wide
        // Size control act as a multiplier instead of an absolute size.
        let typingFont = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let textView = makeEditor(typingFont: typingFont)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteMatchStyleTests.rich"))
        pasteboard.clearContents()
        pasteboard.setData(try foreignRTF("Pasted", fontName: "Times New Roman", size: 48), forType: .rtf)
        pasteboard.setString("Pasted", forType: .string)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .rtf))

        XCTAssertEqual(textView.string, "Pasted")
        let storage = try XCTUnwrap(textView.textStorage)
        var index = 0
        while index < storage.length {
            var effectiveRange = NSRange(location: 0, length: 0)
            let font = try XCTUnwrap(storage.attribute(.font, at: index, effectiveRange: &effectiveRange) as? NSFont)
            XCTAssertEqual(font.pointSize, typingFont.pointSize, accuracy: 0.01)
            XCTAssertEqual(font.familyName, typingFont.familyName)
            index = NSMaxRange(effectiveRange)
        }
    }

    func testPlainStringFlavorStillUsesDefaultPath() {
        let textView = makeEditor(typingFont: NSFont.systemFont(ofSize: 10))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteMatchStyleTests.plain"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(textView.string, "hello")
    }

    func testRTFOnlyPasteboardIsConvertedToTypingStyle() throws {
        // RTF-only pasteboards (no plain-string flavor) must not fall back to
        // rich import — the RTF is decoded to its plain string and inserted
        // with the typing attributes.
        let typingFont = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let textView = makeEditor(typingFont: typingFont)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteMatchStyleTests.rtfOnly"))
        pasteboard.clearContents()
        pasteboard.setData(try foreignRTF("x", fontName: "Times New Roman", size: 48), forType: .rtf)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .rtf))
        XCTAssertEqual(textView.string, "x")
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, typingFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(font.familyName, typingFont.familyName)
    }

    func testHTMLOnlyPasteboardIsConvertedToTypingStyle() throws {
        let typingFont = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let textView = makeEditor(typingFont: typingFont)

        let html = "<span style=\"font-family: 'Times New Roman'; font-size: 48px;\">web</span>"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteMatchStyleTests.htmlOnly"))
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(html.data(using: .utf8)), forType: .html)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .html))
        XCTAssertEqual(textView.string, "web")
        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, typingFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(font.familyName, typingFont.familyName)
    }

    func testRichPasteReplacesActiveSelectionAtTypingStyle() throws {
        // Pasting over a selected foreign-styled run must replace exactly the
        // selection (rangeForUserTextChange), not duplicate or misplace text.
        let typingFont = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        let textView = makeEditor(typingFont: typingFont)
        textView.string = "abcdef"
        textView.setSelectedRange(NSRange(location: 2, length: 2))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteMatchStyleTests.selection"))
        pasteboard.clearContents()
        pasteboard.setData(try foreignRTF("XY", fontName: "Times New Roman", size: 48), forType: .rtf)
        pasteboard.setString("XY", forType: .string)

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .rtf))
        XCTAssertEqual(textView.string, "abXYef")
    }
}
