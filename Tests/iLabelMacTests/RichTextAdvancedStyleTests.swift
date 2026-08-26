import AppKit
import XCTest
@testable import iLabelMac

final class RichTextAdvancedStyleTests: XCTestCase {
    private func baseFont() -> NSFont {
        NSFont.systemFont(ofSize: 12)
    }

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: baseFont(),
            .foregroundColor: NSColor.black,
            .underlineStyle: 0
        ]
    }

    private func decoded(_ data: Data?) throws -> NSAttributedString {
        let data = try XCTUnwrap(data)
        return try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    private func integerAttribute(
        _ key: NSAttributedString.Key,
        in attributed: NSAttributedString,
        at index: Int
    ) -> Int {
        if let number = attributed.attribute(key, at: index, effectiveRange: nil) as? NSNumber {
            return number.intValue
        }
        return attributed.attribute(key, at: index, effectiveRange: nil) as? Int ?? 0
    }

    private func mergeContext() -> MergeContext {
        MergeContext(
            row: [:],
            serialValue: 1,
            rowNumber: 1,
            pageNumber: 1,
            slotNumber: 1,
            isActive: true
        )
    }

    func testRunAttributeTogglesCoverStrikeSuperscriptAndSubscript() {
        let base = baseAttributes()

        let struck = RichTextFormatting.applyingAdvancedAction(
            .strikethrough,
            to: base,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        XCTAssertEqual((struck[.strikethroughStyle] as? NSNumber)?.intValue, NSUnderlineStyle.single.rawValue)

        let superscript = RichTextFormatting.applyingAdvancedAction(
            .superscript,
            to: base,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        XCTAssertEqual((superscript[RichTextFormatting.superscriptAttribute] as? NSNumber)?.intValue, 1)

        let superscriptOff = RichTextFormatting.applyingAdvancedAction(
            .superscript,
            to: superscript,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        XCTAssertEqual((superscriptOff[RichTextFormatting.superscriptAttribute] as? NSNumber)?.intValue, 0)

        let subscripted = RichTextFormatting.applyingAdvancedAction(
            .subscriptText,
            to: superscript,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        XCTAssertEqual((subscripted[RichTextFormatting.superscriptAttribute] as? NSNumber)?.intValue, -1)

        let highlighted = RichTextFormatting.applyingAdvancedAction(
            .highlightColor(RGBAColor(red: 1, green: 1, blue: 0, alpha: 1)),
            to: base,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        let highlightCleared = RichTextFormatting.applyingAdvancedAction(
            .highlightColor(.clear),
            to: highlighted,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        XCTAssertNil(highlightCleared[.backgroundColor])
    }

    func testHighlightAndClearFormattingRoundTripThroughRTF() throws {
        let source = NSAttributedString(string: "H2O", attributes: baseAttributes())
        let sourceData = try XCTUnwrap(source.rtf(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
        let yellow = RGBAColor(red: 1, green: 0.82, blue: 0.15, alpha: 1)

        let highlightedData = RichTextFormatting.rewriting(
            .highlightColor(yellow),
            rtfData: sourceData,
            content: source.string,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        let highlighted = try decoded(highlightedData)
        XCTAssertNotNil(highlighted.attribute(.backgroundColor, at: 1, effectiveRange: nil))

        let clearedData = RichTextFormatting.rewriting(
            .clearFormatting,
            rtfData: highlightedData,
            content: source.string,
            baseFont: baseFont(),
            baseForeground: .black,
            alignment: .center,
            baseUnderline: false
        )
        let cleared = try decoded(clearedData)
        XCTAssertNil(cleared.attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertEqual(integerAttribute(.strikethroughStyle, in: cleared, at: 1), 0)
        XCTAssertEqual(integerAttribute(RichTextFormatting.superscriptAttribute, in: cleared, at: 1), 0)
    }

    func testOutputRendererPreservesAdvancedRunStyles() throws {
        let styled = NSMutableAttributedString(string: "H2O", attributes: baseAttributes())
        styled.addAttribute(
            RichTextFormatting.superscriptAttribute,
            value: -1,
            range: NSRange(location: 1, length: 1)
        )
        styled.addAttribute(
            .backgroundColor,
            value: NSColor.yellow,
            range: NSRange(location: 1, length: 1)
        )
        styled.addAttribute(
            .strikethroughStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 2, length: 1)
        )

        var element = LabelElement.make(.text, index: 1)
        element.content = styled.string
        element.richTextRTF = try XCTUnwrap(styled.rtf(
            from: NSRange(location: 0, length: styled.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: mergeContext(),
            serialSettings: .default
        )

        XCTAssertEqual(integerAttribute(RichTextFormatting.superscriptAttribute, in: rendered, at: 1), -1)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertNotEqual(integerAttribute(.strikethroughStyle, in: rendered, at: 2), 0)
    }

    func testEmojiTextRoundTripsIntoTheOutputRenderer() throws {
        let content = "Sample 🧬✨"
        let attributed = NSAttributedString(string: content, attributes: baseAttributes())
        var element = LabelElement.make(.text, index: 1)
        element.content = content
        element.richTextRTF = try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: mergeContext(),
            serialSettings: .default
        )

        XCTAssertEqual(rendered.string, content)
    }

    @MainActor
    func testStoreAppliesAdvancedStyleWithoutAnActiveEditorView() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let id = try XCTUnwrap(store.selectedElementID)
        store.finishInlineEditing()
        store.updateTextElement(id: id, content: "H2O", richTextRTF: nil)

        store.applyTextStyleAction(.subscriptText)

        let subscripted = try decoded(store.selectedElement?.richTextRTF)
        XCTAssertEqual(
            integerAttribute(RichTextFormatting.superscriptAttribute, in: subscripted, at: 1),
            -1
        )

        store.applyTextStyleAction(.clearFormatting)
        let cleared = try decoded(store.selectedElement?.richTextRTF)
        XCTAssertEqual(
            integerAttribute(RichTextFormatting.superscriptAttribute, in: cleared, at: 1),
            0
        )
        XCTAssertFalse(try XCTUnwrap(store.selectedElement).isBold)
    }

    @MainActor
    func testSnippetInsertionFallsBackWhenInlineEditorIsUnavailable() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let id = try XCTUnwrap(store.selectedElementID)
        store.updateTextElement(id: id, content: "A", richTextRTF: nil)
        store.canvasMode = .page

        store.insertQuickTextPreset("🧬")

        XCTAssertEqual(store.selectedElement?.content, "A🧬")
    }

    @MainActor
    func testTokenInsertionRejectsLayersWithoutContent() throws {
        let store = DocumentStore()
        store.addElement(.rectangle)
        let before = try XCTUnwrap(store.selectedElement).content

        store.insertQuickTextPreset("{{serial}}")

        XCTAssertEqual(store.selectedElement?.content, before)
        XCTAssertEqual(store.statusMessage, "Select text, QR, or barcode content first")
    }

    @MainActor
    func testCircularTextOrientationRoundTripRestoresFullFrame() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let sheet = store.document.sheet

        store.applySelectedTextOrientation(vertical: true)
        let vertical = try XCTUnwrap(store.selectedElement)
        XCTAssertTrue(vertical.verticalTextLayout == true)
        XCTAssertFalse(vertical.usesCircularTextFlow == true)
        XCTAssertLessThan(vertical.frame.width, sheet.labelWidthMM)

        store.applySelectedTextOrientation(vertical: false)
        let horizontal = try XCTUnwrap(store.selectedElement)
        XCTAssertFalse(horizontal.verticalTextLayout == true)
        XCTAssertTrue(horizontal.usesCircularTextFlow == true)
        XCTAssertEqual(horizontal.frame.x, 0)
        XCTAssertEqual(horizontal.frame.y, 0)
        XCTAssertEqual(horizontal.frame.width, sheet.labelWidthMM)
        XCTAssertEqual(horizontal.frame.height, sheet.labelHeightMM)
    }
}
