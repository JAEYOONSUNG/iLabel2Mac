import XCTest
@testable import iLabelMac

@MainActor
final class PrintQueueStoreTests: XCTestCase {
    func testQueuedLabelIsSnapshotAndLaterEditsDoNotOverwriteIt() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.updateTextElement(id: elementID, content: "First value", richTextRTF: nil)
        store.document.serial.end = 2
        store.enqueueCurrentLabel()

        store.updateTextElement(id: elementID, content: "Second value", richTextRTF: nil)
        store.document.serial.end = 1
        store.selectPlacementStart(at: 2)
        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.printBatches.count, 2)
        XCTAssertEqual(store.document.queuedLabelCount, 3)
        XCTAssertEqual(store.document.printBatches[0].quantity, 2)
        XCTAssertEqual(store.document.printBatches[0].elements.first?.content, "First value")
        XCTAssertEqual(store.document.printBatches[1].elements.first?.content, "Second value")
    }

    func testCaptureUsesAndPreservesCurrentNumberingSetup() throws {
        let store = DocumentStore()
        store.addElement(.text)

        store.document.serial = SerialSettings(
            mode: .rangedSets,
            start: 4,
            step: 2,
            end: 8,
            repeatSets: 2,
            digits: 2,
            prefix: "[",
            suffix: "]"
        )
        store.enqueueCurrentLabel()

        let batch = try XCTUnwrap(store.document.printBatches.first)
        XCTAssertEqual(batch.quantity, 6)
        XCTAssertEqual(batch.serialSettings, store.document.serial)
        XCTAssertNil(batch.dataTable)

        let values = (0..<6).map {
            store.document.renderPayload(slotIndex: $0, pageIndex: 0)
        }
        XCTAssertEqual(values.map(\.context.serialValue), [4, 6, 8, 4, 6, 8])
        XCTAssertEqual(values.map(\.serialSettings), Array(repeating: store.document.serial, count: 6))
    }

    func testStackedCapturesKeepIndependentCountsAndNumbering() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.document.serial.start = 1
        store.document.serial.end = 2
        store.updateTextElement(id: elementID, content: "FIRST {{serial}}", richTextRTF: nil)
        store.enqueueCurrentLabel()

        store.document.serial.start = 10
        store.document.serial.end = 12
        store.updateTextElement(id: elementID, content: "SECOND {{serial}}", richTextRTF: nil)
        store.selectPlacementStart(at: 2)
        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.printBatches.map(\.quantity), [2, 3])
        let payloads = (0..<5).map {
            store.document.renderPayload(slotIndex: $0, pageIndex: 0)
        }
        XCTAssertEqual(payloads.map(\.context.serialValue), [1, 2, 10, 11, 12])
        XCTAssertEqual(
            payloads.map { $0.elements.first?.content },
            ["FIRST {{serial}}", "FIRST {{serial}}", "SECOND {{serial}}", "SECOND {{serial}}", "SECOND {{serial}}"]
        )
    }

    func testCapturedPositionsStayFixedWhenNextStartPositionChanges() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.document.serial.start = 1
        store.document.serial.end = 2
        store.updateTextElement(id: elementID, content: "FIRST", richTextRTF: nil)
        store.enqueueCurrentLabel()

        store.selectPlacementStart(at: 14)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 0, pageIndex: 0)
                .elements.first?.content,
            "FIRST"
        )
        XCTAssertFalse(
            store.document.renderPayload(slotIndex: 14, pageIndex: 0)
                .context.isActive
        )

        store.updateTextElement(id: elementID, content: "SECOND", richTextRTF: nil)
        let draftPlan = try XCTUnwrap(store.pendingDraftPlan)
        XCTAssertNil(store.document.firstPlacementConflict(for: draftPlan))
        let capturedPreview = store.document.interactivePreviewPayload(
            slotIndex: 0,
            pageIndex: 0,
            validDraftPlan: draftPlan
        )
        let draftPreview = store.document.interactivePreviewPayload(
            slotIndex: 14,
            pageIndex: 0,
            validDraftPlan: draftPlan
        )
        XCTAssertEqual(
            capturedPreview.source,
            .captured(store.document.printBatches[0].id)
        )
        XCTAssertEqual(capturedPreview.payload.elements.first?.content, "FIRST")
        XCTAssertEqual(draftPreview.source, .draft)
        XCTAssertTrue(draftPreview.payload.context.isActive)
        XCTAssertEqual(draftPreview.payload.elements.first?.content, "SECOND")
        XCTAssertEqual(
            store.document.draftPreviewSlotIndices(
                pageIndex: 0,
                plan: draftPlan
            ),
            [14, 15]
        )
        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.printBatches.count, 2)
        XCTAssertNil(store.pendingDraftPlan)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 0, pageIndex: 0)
                .elements.first?.content,
            "FIRST"
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 14, pageIndex: 0)
                .elements.first?.content,
            "SECOND"
        )

        store.selectPlacementStart(at: 28)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 0, pageIndex: 0).batchID,
            store.document.printBatches[0].id
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 14, pageIndex: 0).batchID,
            store.document.printBatches[1].id
        )

        let firstID = store.document.printBatches[0].id
        let secondID = store.document.printBatches[1].id
        store.movePrintBatch(id: secondID, by: -1)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 0, pageIndex: 0).batchID,
            firstID
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 14, pageIndex: 0).batchID,
            secondID
        )

        store.removePrintBatch(id: firstID)
        XCTAssertFalse(
            store.document.renderPayload(slotIndex: 0, pageIndex: 0)
                .context.isActive
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 14, pageIndex: 0).batchID,
            secondID
        )
    }

    func testOverlappingCaptureIsRejectedWithoutChangingExistingCapture() throws {
        let store = DocumentStore()
        store.addElement(.text)
        store.document.serial.end = 2
        store.enqueueCurrentLabel()
        let original = try XCTUnwrap(store.document.printBatches.first)

        XCTAssertNil(store.pendingDraftPlan)
        XCTAssertFalse(store.canCaptureCurrentLabel)
        store.selectPlacementStart(at: 0)

        XCTAssertNil(store.pendingDraftPlan)
        XCTAssertNotNil(store.captureQueueIssue)
        XCTAssertTrue(store.statusMessage.contains("(1,1)"))

        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.printBatches.count, 1)
        XCTAssertEqual(store.document.printBatches.first, original)
        XCTAssertNotNil(store.captureQueueIssue)
        XCTAssertTrue(store.statusMessage.contains("empty start position"))
    }

    func testCaptureRejectsQueueLargerThanSafetyLimit() {
        let store = DocumentStore()
        store.addElement(.text)
        store.document.serial = SerialSettings(
            mode: .rangedSets,
            start: 1,
            step: 1,
            end: PrintBatch.quantityRange.upperBound + 1,
            repeatSets: 1,
            digits: 1,
            prefix: "",
            suffix: ""
        )

        store.enqueueCurrentLabel()

        XCTAssertFalse(store.document.hasQueuedLabels)
        XCTAssertNotNil(store.captureQueueIssue)
        XCTAssertTrue(store.statusMessage.contains("queue limit"))
    }

    func testVerticalStartSelectionBeginsAtClickedSlot() {
        let store = DocumentStore()
        store.document.sheet.columns = 2
        store.document.sheet.rows = 2
        store.document.placement.fillDirection = .horizontal

        store.selectPlacementStart(at: 1)
        XCTAssertEqual(store.document.activeSlotIndices.first, 1)
        store.updatePlacementFillDirection(.vertical)

        XCTAssertEqual(store.document.activeSlotIndices.first, 1)
    }

    func testFullPrintedPageLeavesBlankStagingPageForNextCapture() throws {
        let store = DocumentStore()
        store.document.sheet.columns = 2
        store.document.sheet.rows = 2
        store.document.placement.selectedSlotIndices = []
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)
        store.document.serial.start = 1
        store.document.serial.end = 4
        store.updateTextElement(id: elementID, content: "PAGE ONE", richTextRTF: nil)
        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.pageCount, 1)
        XCTAssertEqual(store.navigationPageCount, 2)
        store.movePage(delta: 1)
        XCTAssertTrue(store.isCaptureStagingPage)

        store.selectPlacementStart(at: 0)
        XCTAssertEqual(store.currentPageIndex, 1)
        XCTAssertEqual(store.pendingDraftPageIndex, 1)
        store.document.serial.start = 101
        store.document.serial.end = 101
        store.updateTextElement(id: elementID, content: "PAGE TWO", richTextRTF: nil)
        let draftPlan = try XCTUnwrap(store.pendingDraftPlan)
        XCTAssertNil(store.document.firstPlacementConflict(for: draftPlan))
        let draft = store.document.interactivePreviewPayload(
            slotIndex: 0,
            pageIndex: 1,
            validDraftPlan: draftPlan
        )
        XCTAssertEqual(draft.source, .draft)
        XCTAssertTrue(draft.payload.context.isActive)
        XCTAssertEqual(draft.payload.context.serialValue, 101)
        XCTAssertEqual(draft.payload.context.pageNumber, 2)
        XCTAssertFalse(
            store.document.renderPayload(slotIndex: 0, pageIndex: 1)
                .context.isActive
        )
        store.enqueueCurrentLabel()

        XCTAssertEqual(store.document.pageCount, 2)
        XCTAssertEqual(store.document.printBatches.last?.startPageIndex, 1)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 0, pageIndex: 1)
                .elements.first?.content,
            "PAGE TWO"
        )
    }

    func testSheetGeometryIsLockedWhileCapturesExist() {
        let store = DocumentStore()
        store.addElement(.text)
        store.document.serial.end = 1
        store.enqueueCurrentLabel()
        let originalColumns = store.document.sheet.columns

        store.updateSheet { $0.columns = originalColumns - 1 }

        XCTAssertEqual(store.document.sheet.columns, originalColumns)
        XCTAssertTrue(store.statusMessage.contains("Reset the capture queue"))
    }

    func testCurrentEditorContextIgnoresCapturedNumbering() throws {
        let store = DocumentStore()
        store.addElement(.text)
        store.document.serial.start = 1
        store.document.serial.end = 2
        store.enqueueCurrentLabel()

        store.document.serial.start = 10
        store.document.serial.end = 12

        let current = store.document.currentSetupMergeContext(slotIndex: 0, pageIndex: 0)
        let captured = store.document.mergeContext(slotIndex: 0, pageIndex: 0)
        XCTAssertEqual(current.serialValue, 10)
        XCTAssertEqual(captured.serialValue, 1)
    }

    func testLegacy680FramesMigrateForCanvasAndCapturedSnapshots() throws {
        let store = DocumentStore()
        let fullFrame = RectMM(
            x: 0,
            y: 0,
            width: store.document.sheet.labelWidthMM,
            height: store.document.sheet.labelHeightMM
        )
        var legacyText = LabelElement.make(.text, index: 1)
        legacyText.usesCircularTextFlow = nil
        legacyText.frame = RectMM(x: 0.48, y: 0.36, width: 11.04, height: 11.04)
        store.document.elements = [legacyText]
        store.document.printQueue = [
            PrintBatch(
                name: "Legacy capture",
                quantity: 1,
                elements: [legacyText]
            )
        ]

        store.normalizeCircleTextFrames(in: &store.document)

        XCTAssertEqual(store.document.elements.first?.frame, fullFrame)
        XCTAssertEqual(store.document.elements.first?.usesCircularTextFlow, true)
        XCTAssertEqual(store.document.printBatches.first?.elements.first?.frame, fullFrame)
        XCTAssertEqual(
            store.document.printBatches.first?.elements.first?.usesCircularTextFlow,
            true
        )
    }

    func testCaptureSnapshotsCSVRowsAndUsesTheirCount() throws {
        let store = DocumentStore()
        store.addElement(.text)
        store.document.dataTable = DataTable(
            headers: ["sample"],
            rows: [["sample": "A"], ["sample": "B"], ["sample": "C"]]
        )

        store.enqueueCurrentLabel()
        store.document.dataTable = DataTable(
            headers: ["sample"],
            rows: [["sample": "CHANGED"]]
        )

        let batch = try XCTUnwrap(store.document.printBatches.first)
        XCTAssertEqual(batch.quantity, 3)
        XCTAssertEqual(
            (0..<3).map {
                store.document.renderPayload(slotIndex: $0, pageIndex: 0).context.row["sample"]
            },
            ["A", "B", "C"]
        )
    }

    func testQueueMutationParticipatesInUndo() {
        let store = DocumentStore()
        store.addElement(.text)
        store.clearUndoHistory()

        store.enqueueCurrentLabel()
        XCTAssertTrue(store.document.hasQueuedLabels)

        store.undo()
        XCTAssertFalse(store.document.hasQueuedLabels)
    }

    func testCircleTextEditsKeepFullCircularFlowFrame() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)
        let labelWidth = store.document.sheet.labelWidthMM
        let labelHeight = store.document.sheet.labelHeightMM

        store.updateElement(id: elementID) { element in
            element.frame = RectMM(
                x: 2,
                y: 2,
                width: labelWidth / 2,
                height: labelHeight / 2
            )
        }

        let frame = try XCTUnwrap(store.document.elements.first(where: { $0.id == elementID })?.frame)
        XCTAssertEqual(frame, RectMM(x: 0, y: 0, width: labelWidth, height: labelHeight))
        XCTAssertEqual(store.document.elements.first?.usesCircularTextFlow, true)
    }

    func testActivatingEmptyCircularLabelCreatesCenteredEditableText() throws {
        let store = DocumentStore()
        store.document.elements = []
        store.document.sheet.shape = .circle

        store.activatePrimaryTextElement()

        let element = try XCTUnwrap(store.document.elements.first)
        XCTAssertEqual(element.type, .text)
        XCTAssertEqual(
            element.frame,
            RectMM(
                x: 0,
                y: 0,
                width: store.document.sheet.labelWidthMM,
                height: store.document.sheet.labelHeightMM
            )
        )
        XCTAssertEqual(element.usesCircularTextFlow, true)
        XCTAssertEqual(store.selectedElementID, element.id)
        XCTAssertEqual(store.editingElementID, element.id)
    }

    func testEditingACaptureRoundTripsItBackIntoPlace() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.document.serial.end = 2
        store.updateTextElement(id: elementID, content: "FIRST {{serial}}", richTextRTF: nil)
        store.enqueueCurrentLabel()

        store.updateTextElement(id: elementID, content: "SECOND {{serial}}", richTextRTF: nil)
        store.selectPlacementStart(at: 2)
        store.enqueueCurrentLabel()

        let firstID = try XCTUnwrap(store.document.printBatches.first?.id)
        let secondID = try XCTUnwrap(store.document.printBatches.last?.id)

        store.beginEditingPrintBatch(id: firstID)

        // The batch leaves the queue and its snapshot becomes the draft.
        XCTAssertEqual(store.document.printBatches.map(\.id), [secondID])
        XCTAssertEqual(store.document.elements.first?.content, "FIRST {{serial}}")
        XCTAssertEqual(store.pendingDraftPageIndex, 0)
        XCTAssertNotNil(store.printBatchEditSession)
        // Its former slots are free while the batch is checked out.
        XCTAssertNil(store.document.renderPayload(slotIndex: 0, pageIndex: 0).batchID)

        let editedElementID = try XCTUnwrap(store.selectedElementID)
        store.updateTextElement(id: editedElementID, content: "FIRST v2 {{serial}}", richTextRTF: nil)
        store.enqueueCurrentLabel()

        // Update Capture restores identity, queue order, and sheet position.
        XCTAssertNil(store.printBatchEditSession)
        XCTAssertEqual(store.document.printBatches.map(\.id), [firstID, secondID])
        XCTAssertEqual(
            store.document.printBatches.first?.elements.first?.content,
            "FIRST v2 {{serial}}"
        )
        XCTAssertEqual(store.document.renderPayload(slotIndex: 0, pageIndex: 0).batchID, firstID)
        XCTAssertEqual(store.document.renderPayload(slotIndex: 2, pageIndex: 0).batchID, secondID)
    }

    func testCancellingACaptureEditRestoresTheQueueUnchanged() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)
        store.updateTextElement(id: elementID, content: "KEEP ME", richTextRTF: nil)
        store.enqueueCurrentLabel()
        let batchID = try XCTUnwrap(store.document.printBatches.first?.id)

        store.beginEditingPrintBatch(id: batchID)
        let editedElementID = try XCTUnwrap(store.selectedElementID)
        store.updateTextElement(id: editedElementID, content: "DISCARD ME", richTextRTF: nil)
        store.cancelPrintBatchEdit()

        XCTAssertNil(store.printBatchEditSession)
        XCTAssertEqual(store.document.printBatches.map(\.id), [batchID])
        XCTAssertEqual(store.document.printBatches.first?.elements.first?.content, "KEEP ME")
        XCTAssertEqual(store.document.elements.first?.content, "KEEP ME")
    }

    func testRepositioningACaptureMovesItsFixedSlots() throws {
        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.document.serial.end = 2
        store.updateTextElement(id: elementID, content: "FIRST {{serial}}", richTextRTF: nil)
        store.enqueueCurrentLabel()

        store.updateTextElement(id: elementID, content: "SECOND {{serial}}", richTextRTF: nil)
        store.selectPlacementStart(at: 2)
        store.enqueueCurrentLabel()

        let firstID = try XCTUnwrap(store.document.printBatches.first?.id)
        let secondID = try XCTUnwrap(store.document.printBatches.last?.id)

        store.beginMovingPrintBatch(id: firstID)
        XCTAssertNotNil(store.printBatchMoveSession)

        // Landing on another capture's fixed slots is rejected and keeps the
        // move armed so the user can pick a different position.
        store.selectPlacementStart(at: 2)
        XCTAssertNotNil(store.printBatchMoveSession)
        XCTAssertNotNil(store.captureQueueIssue)

        store.selectPlacementStart(at: 6)
        XCTAssertNil(store.printBatchMoveSession)
        XCTAssertNil(store.captureQueueIssue)
        XCTAssertEqual(store.document.printBatches.map(\.id), [firstID, secondID])
        XCTAssertNil(store.document.renderPayload(slotIndex: 0, pageIndex: 0).batchID)
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 6, pageIndex: 0).batchID,
            firstID
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 6, pageIndex: 0).context.serialValue,
            1
        )
        XCTAssertEqual(
            store.document.renderPayload(slotIndex: 2, pageIndex: 0).batchID,
            secondID
        )
    }
}
