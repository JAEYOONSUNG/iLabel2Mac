import XCTest
@testable import iLabelMac

@MainActor
final class Default680Tests: XCTestCase {
    func testStarterIsCanonicalBlank680Document() {
        assertCanonical680(LabelDocument.starter)
    }

    func testStoreStartsWithCanonicalBlank680Document() {
        assertCanonical680(DocumentStore().document)
    }

    func testNewDocumentAlwaysReturnsToCanonical680() {
        let store = DocumentStore()
        store.document.sheet = SheetTemplate.presets[0]
        store.document.title = "Changed"
        store.document.formatCode = "999"
        store.document.formatFamily = .rollLabel
        store.document.elements = [.make(.text, index: 1)]

        store.newDocument()

        assertCanonical680(store.document)
    }

    private func assertCanonical680(
        _ document: LabelDocument,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(document.title, "680", file: file, line: line)
        XCTAssertEqual(document.sheet, .default680, file: file, line: line)
        XCTAssertTrue(document.elements.isEmpty, file: file, line: line)
        XCTAssertEqual(document.formatCode, "680", file: file, line: line)
        XCTAssertEqual(document.formatFamily, .a4Label, file: file, line: line)
        XCTAssertEqual(
            document.formatSourceURL,
            "https://www.label.kr/Goods/Detail/680",
            file: file,
            line: line
        )
        XCTAssertEqual(
            document.formatPDFTemplateURL,
            "https://images.label.kr/pds/template/680_line.pdf",
            file: file,
            line: line
        )
    }
}
