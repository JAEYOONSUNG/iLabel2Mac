import XCTest
@testable import iLabelMac

@MainActor
final class TextElementUpdateTests: XCTestCase {
    private func makeRTF(_ string: String, bold: Bool = true) -> Data {
        let font = bold
            ? NSFont.boldSystemFont(ofSize: 12)
            : NSFont.systemFont(ofSize: 12)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        return attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )!
    }

    func testUpdateTextElementKeepsContentAndRTFConsistent() {
        let store = DocumentStore()
        store.addElement(.text)
        guard let id = store.selectedElementID else {
            return XCTFail("addElement should select the new element")
        }

        let rtf = makeRTF("Hello")
        store.updateTextElement(id: id, content: "Hello", richTextRTF: rtf)

        let element = store.document.elements.first { $0.id == id }
        XCTAssertEqual(element?.content, "Hello")
        // content.didSet drops RTF whose plain text diverges from content;
        // the atomic update must leave a matching pair, so RTF survives.
        XCTAssertNotNil(element?.richTextRTF)
        XCTAssertEqual(LabelElement.plainText(fromRTF: element?.richTextRTF), "Hello")
    }

    func testContentEditFromOtherSurfaceDropsStaleRTF() {
        let store = DocumentStore()
        store.addElement(.text)
        guard let id = store.selectedElementID else {
            return XCTFail("addElement should select the new element")
        }

        store.updateTextElement(id: id, content: "Hello", richTextRTF: makeRTF("Hello"))
        store.updateElement(id: id) { $0.content = "Changed elsewhere" }

        let element = store.document.elements.first { $0.id == id }
        XCTAssertEqual(element?.content, "Changed elsewhere")
        XCTAssertNil(element?.richTextRTF, "stale RTF must not shadow the newer plain-text edit")
    }

    func testFontActionsApplyElementWideWithoutEditorSelection() {
        let store = DocumentStore()
        store.addElement(.text)
        // addElement opens the inline editor; with no editor view alive (or no
        // dragged selection) the request must fall through element-wide —
        // this is the "Size field looks dead" regression.
        store.applyTextStyleAction(.fontSize(24))
        XCTAssertEqual(store.selectedElement?.fontSize, 24)

        store.applyTextStyleAction(.fontFamily("Courier"))
        XCTAssertEqual(store.selectedElement?.fontName, "Courier")
    }

    func testPreviewRefreshesImmediatelyOutsideEditing() {
        let store = DocumentStore()
        store.addElement(.text)
        guard let id = store.selectedElementID else {
            return XCTFail("addElement should select the new element")
        }
        store.finishInlineEditing()

        // Outside editing the leading edge must fire: a single edit shows up
        // in the preview immediately once the throttle window has elapsed.
        Thread.sleep(forTimeInterval: 0.15)
        store.updateTextElement(id: id, content: "H", richTextRTF: nil)
        let previewElement = store.previewDocument.elements.first { $0.id == id }
        XCTAssertEqual(previewElement?.content, "H")
    }

    func testPreviewCatchesUpWhileEditingAndRefreshesOnCommit() {
        let store = DocumentStore()
        store.addElement(.text)
        guard let id = store.selectedElementID else {
            return XCTFail("addElement should select the new element")
        }

        // While the inline editor is open, keystrokes must NOT render the
        // preview synchronously (that was the typing lag)...
        store.updateTextElement(id: id, content: "H", richTextRTF: nil)
        XCTAssertNotEqual(store.previewDocument.elements.first { $0.id == id }?.content, "H")

        // ...but the pending trailing refresh publishes the latest content.
        let caughtUp = expectation(description: "preview catches up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { caughtUp.fulfill() }
        wait(for: [caughtUp], timeout: 3)
        XCTAssertEqual(store.previewDocument.elements.first { $0.id == id }?.content, "H")

        // Finishing the edit refreshes immediately.
        store.updateTextElement(id: id, content: "Hi", richTextRTF: nil)
        store.finishInlineEditing()
        XCTAssertEqual(store.previewDocument.elements.first { $0.id == id }?.content, "Hi")
    }
}
