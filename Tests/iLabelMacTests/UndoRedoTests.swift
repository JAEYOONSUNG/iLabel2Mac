import XCTest
@testable import iLabelMac

@MainActor
final class UndoRedoTests: XCTestCase {
    func testAddElementIsUndoableAndRedoable() {
        let store = DocumentStore()
        let initialCount = store.document.elements.count
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)

        store.addElement(.text)
        XCTAssertEqual(store.document.elements.count, initialCount + 1)
        XCTAssertTrue(store.canUndo)

        store.undo()
        XCTAssertEqual(store.document.elements.count, initialCount)
        XCTAssertTrue(store.canRedo)

        store.redo()
        XCTAssertEqual(store.document.elements.count, initialCount + 1)
        XCTAssertFalse(store.canRedo)
    }

    func testDeleteIsUndoable() {
        let store = DocumentStore()
        store.addElement(.text)
        let id = store.selectedElementID
        let countWithElement = store.document.elements.count

        store.deleteSelected()
        XCTAssertEqual(store.document.elements.count, countWithElement - 1)

        store.undo()
        XCTAssertEqual(store.document.elements.count, countWithElement)
        XCTAssertTrue(store.document.elements.contains { $0.id == id })
    }

    func testNewDocumentClearsHistory() {
        let store = DocumentStore()
        store.addElement(.text)
        XCTAssertTrue(store.canUndo)

        store.newDocument()
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
    }
}
