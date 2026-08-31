import XCTest
@testable import iLabelMac

/// A fresh session (or New) starts on the label stock the user last worked
/// with. The stores in these tests share one preference store, standing in
/// for two app launches on the same machine.
@MainActor
final class LastUsedSheetTests: XCTestCase {
    func testNewStoreStartsOnLastUsedOfficialFormat() {
        let machine = InMemoryPreferenceStore()
        let first = DocumentStore(preferences: machine)
        guard let target = first.officialFormats.first(where: { $0.code != first.document.formatCode }) else {
            return XCTFail("The catalog needs a second format to switch to")
        }
        first.applyOfficialFormat(code: target.code)

        let second = DocumentStore(preferences: machine)
        XCTAssertEqual(second.document.formatCode, target.code)
        XCTAssertEqual(second.document.sheet, target.sheetTemplate)
        XCTAssertEqual(second.document.title, target.code)
        XCTAssertTrue(second.document.elements.isEmpty)
    }

    func testNewStoreStartsOnLastUsedCustomSheet() {
        let machine = InMemoryPreferenceStore()
        let first = DocumentStore(preferences: machine)
        first.updateSheet { sheet in
            sheet.labelWidthMM = 33
            sheet.labelHeightMM = 21
        }

        let second = DocumentStore(preferences: machine)
        XCTAssertNil(second.document.formatCode)
        XCTAssertEqual(second.document.sheet.labelWidthMM, 33)
        XCTAssertEqual(second.document.sheet.labelHeightMM, 21)
    }

    func testNewDocumentKeepsLastUsedFormat() {
        let store = DocumentStore()
        guard let target = store.officialFormats.first(where: { $0.code != store.document.formatCode }) else {
            return XCTFail("The catalog needs a second format to switch to")
        }
        store.applyOfficialFormat(code: target.code)
        store.newDocument()
        XCTAssertEqual(store.document.formatCode, target.code)
        XCTAssertTrue(store.document.elements.isEmpty)
    }

    func testStoresWithoutSharedPreferencesStayCanonical() {
        let first = DocumentStore()
        first.updateSheet { sheet in
            sheet.labelWidthMM = 55
        }
        // A store with its own (test-isolated) preferences never sees another
        // store's geometry — the regression that broke the canonical-680 suite.
        XCTAssertNotEqual(DocumentStore().document.sheet.labelWidthMM, 55)
    }
}
