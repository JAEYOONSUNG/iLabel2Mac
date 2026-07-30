import AppKit
import CoreText
import PDFKit
import XCTest
@testable import iLabelMac

final class PrintQueueTests: XCTestCase {
    func testPrintBatchAndQueueRoundTripThroughCodable() throws {
        let batchID = UUID(uuidString: "88A8F9ED-F40E-47BA-B1A5-57CA96949712")!
        var queuedElement = LabelElement.make(.text, index: 1)
        queuedElement.content = "Queued design"

        var document = LabelDocument.starter
        document.printQueue = [
            PrintBatch(
                id: batchID,
                name: "First design",
                quantity: 3,
                elements: [queuedElement],
                serialSettings: SerialSettings(
                    mode: .rangedSets,
                    start: 3,
                    step: 2,
                    end: 7,
                    repeatSets: 1,
                    digits: 2,
                    prefix: "[",
                    suffix: "]"
                ),
                dataTable: DataTable(
                    headers: ["sample"],
                    rows: [["sample": "A"], ["sample": "B"], ["sample": "C"]]
                ),
                capturedPlacement: PlacementSettings(
                    selectedSlotIndices: [3, 4, 5],
                    fillDirection: .vertical
                ),
                startPageIndex: 2,
                startSlotOffset: 1,
                legacySequenceOffset: 7
            )
        ]

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(LabelDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.printBatches.first?.id, batchID)
        XCTAssertEqual(decoded.printBatches.first?.name, "First design")
        XCTAssertEqual(decoded.printBatches.first?.serialSettings, document.printBatches.first?.serialSettings)
        XCTAssertEqual(decoded.printBatches.first?.dataTable, document.printBatches.first?.dataTable)
        XCTAssertEqual(
            decoded.printBatches.first?.capturedPlacement,
            document.printBatches.first?.capturedPlacement
        )
        XCTAssertEqual(decoded.printBatches.first?.startPageIndex, 2)
        XCTAssertEqual(decoded.printBatches.first?.startSlotOffset, 1)
        XCTAssertEqual(decoded.printBatches.first?.legacySequenceOffset, 7)
        XCTAssertEqual(decoded.queuedLabelCount, 3)
        XCTAssertTrue(decoded.hasQueuedLabels)
    }

    func testPrintBatchClampsNonPositiveQuantitiesFromMutationAndJSON() throws {
        var batch = PrintBatch(name: "Invalid quantity", quantity: 0, elements: [])
        XCTAssertEqual(batch.quantity, 1)

        batch.quantity = -8
        XCTAssertEqual(batch.quantity, 1)

        let encoded = try JSONEncoder().encode(batch)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["quantity"] = -99
        let invalidJSON = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PrintBatch.self, from: invalidJSON)

        XCTAssertEqual(decoded.quantity, 1)

        object["quantity"] = Int.max
        let oversizedJSON = try JSONSerialization.data(withJSONObject: object)
        let oversized = try JSONDecoder().decode(PrintBatch.self, from: oversizedJSON)
        XCTAssertEqual(oversized.quantity, PrintBatch.quantityRange.upperBound)
    }

    func testOlderDocumentWithoutPrintQueueStillDecodes() throws {
        let encoded = try JSONEncoder().encode(LabelDocument.starter)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("\"printQueue\""))

        let decoded = try JSONDecoder().decode(LabelDocument.self, from: encoded)
        XCTAssertNil(decoded.printQueue)
        XCTAssertEqual(decoded.printBatches, [])
        XCTAssertEqual(decoded.queuedLabelCount, 0)
        XCTAssertFalse(decoded.hasQueuedLabels)
    }

    func testQueueQuantityDrivesMappingActivityAndPageCount() throws {
        var firstElement = LabelElement.make(.text, index: 1)
        firstElement.content = "FIRST"
        var secondElement = LabelElement.make(.text, index: 2)
        secondElement.content = "SECOND"

        let first = PrintBatch(name: "First", quantity: 2, elements: [firstElement])
        let second = PrintBatch(name: "Second", quantity: 3, elements: [secondElement])

        var document = LabelDocument.starter
        document.sheet.columns = 2
        document.sheet.rows = 2
        document.placement.selectedSlotIndices = [0, 3]
        document.placement.fillDirection = .horizontal
        document.dataTable = DataTable(
            headers: ["value"],
            rows: (0..<20).map { ["value": "\($0)"] }
        )
        document.serial = SerialSettings(
            mode: .rangedSets,
            start: 10,
            step: 2,
            end: 10,
            repeatSets: 1,
            digits: 1,
            prefix: "",
            suffix: ""
        )
        document.printQueue = [first, second]

        XCTAssertEqual(document.mergeRowCount, 5, "queue quantity must override CSV and serial counts")
        XCTAssertEqual(document.pageCapacity, 2)
        XCTAssertEqual(document.pageCount, 3)

        XCTAssertEqual(document.queuedBatch(atGlobalIndex: 0)?.id, first.id)
        XCTAssertEqual(document.queuedBatch(atGlobalIndex: 1)?.id, first.id)
        XCTAssertEqual(document.queuedBatch(atGlobalIndex: 2)?.id, second.id)
        XCTAssertEqual(document.queuedBatch(atGlobalIndex: 4)?.id, second.id)
        XCTAssertNil(document.queuedBatch(atGlobalIndex: 5))

        let firstPayload = document.renderPayload(slotIndex: 0, pageIndex: 0)
        XCTAssertEqual(firstPayload.batchID, first.id)
        XCTAssertEqual(firstPayload.elements.map(\.content), ["FIRST"])
        XCTAssertTrue(firstPayload.context.isActive)

        let secondPayload = document.renderPayload(slotIndex: 0, pageIndex: 1)
        XCTAssertEqual(secondPayload.batchID, second.id)
        XCTAssertEqual(secondPayload.elements.map(\.content), ["SECOND"])
        XCTAssertTrue(secondPayload.context.isActive)

        let lastPayload = document.renderPayload(slotIndex: 0, pageIndex: 2)
        XCTAssertTrue(lastPayload.context.isActive)
        XCTAssertEqual(
            lastPayload.context.serialValue,
            18,
            "queue serials must continue after the configured finite serial range ends"
        )

        let inactivePayload = document.renderPayload(slotIndex: 3, pageIndex: 2)
        XCTAssertFalse(inactivePayload.context.isActive)
        XCTAssertNil(inactivePayload.batchID)
    }

    func testQueueMappingKeepsVerticalSelectedSlotOrder() {
        let batches = (0..<4).map { index -> PrintBatch in
            var element = LabelElement.make(.text, index: index + 1)
            element.content = "\(index)"
            return PrintBatch(name: "\(index)", quantity: 1, elements: [element])
        }

        var document = LabelDocument.starter
        document.sheet.columns = 2
        document.sheet.rows = 2
        document.placement.selectedSlotIndices = [0, 1, 2, 3]
        document.placement.fillDirection = .vertical
        document.printQueue = batches

        XCTAssertEqual(document.activeSlotIndices, [0, 2, 1, 3])
        XCTAssertEqual(document.renderPayload(slotIndex: 0, pageIndex: 0).batchID, batches[0].id)
        XCTAssertEqual(document.renderPayload(slotIndex: 2, pageIndex: 0).batchID, batches[1].id)
        XCTAssertEqual(document.renderPayload(slotIndex: 1, pageIndex: 0).batchID, batches[2].id)
        XCTAssertEqual(document.renderPayload(slotIndex: 3, pageIndex: 0).batchID, batches[3].id)
    }

    func testCapturedBatchesUseIndependentFixedPositionsAcrossPages() throws {
        var firstElement = LabelElement.make(.text, index: 1)
        firstElement.content = "A"
        var secondElement = LabelElement.make(.text, index: 2)
        secondElement.content = "B"

        let first = PrintBatch(
            name: "A",
            quantity: 3,
            elements: [firstElement],
            serialSettings: SerialSettings(
                mode: .rangedSets,
                start: 1,
                step: 1,
                end: 3,
                repeatSets: 1,
                digits: 1,
                prefix: "",
                suffix: ""
            ),
            capturedPlacement: PlacementSettings(
                selectedSlotIndices: [2, 3],
                fillDirection: .horizontal
            ),
            startPageIndex: 0
        )
        let second = PrintBatch(
            name: "B",
            quantity: 3,
            elements: [secondElement],
            serialSettings: SerialSettings(
                mode: .rangedSets,
                start: 10,
                step: 1,
                end: 12,
                repeatSets: 1,
                digits: 1,
                prefix: "",
                suffix: ""
            ),
            capturedPlacement: PlacementSettings(
                selectedSlotIndices: [0, 1],
                fillDirection: .horizontal
            ),
            startPageIndex: 0
        )

        var document = LabelDocument.starter
        document.sheet.columns = 2
        document.sheet.rows = 2
        document.placement.selectedSlotIndices = [3]
        document.printQueue = [first, second]

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.visiblePreviewSlotIndices(pageIndex: 0), [0, 1, 2, 3])
        XCTAssertEqual(document.visiblePreviewSlotIndices(pageIndex: 1), [0, 2])
        XCTAssertEqual(
            (0..<4).map {
                document.renderPayload(slotIndex: $0, pageIndex: 0)
                    .elements.first?.content
            },
            ["B", "B", "A", "A"]
        )
        XCTAssertEqual(
            document.renderPayload(slotIndex: 0, pageIndex: 1).context.serialValue,
            12
        )
        XCTAssertEqual(
            document.renderPayload(slotIndex: 2, pageIndex: 1).context.serialValue,
            3
        )

        document.placement.selectedSlotIndices = [1]
        document.placement.fillDirection = .vertical
        XCTAssertEqual(
            (0..<4).map {
                document.renderPayload(slotIndex: $0, pageIndex: 0).batchID
            },
            [second.id, second.id, first.id, first.id]
        )

        let pdfData = PageRenderer.pdfDataAllPages(document: document)
        let pdf = try XCTUnwrap(PDFDocument(data: pdfData))
        XCTAssertEqual(pdf.pageCount, 2)
    }

    func testLegacyBatchWithoutCapturedPlacementStillUsesGlobalQueueMapping() throws {
        let batch = PrintBatch(name: "Legacy", quantity: 1, elements: [])
        let encoded = try JSONEncoder().encode(batch)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "capturedPlacement")
        object.removeValue(forKey: "startPageIndex")
        object.removeValue(forKey: "startSlotOffset")
        object.removeValue(forKey: "legacySequenceOffset")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PrintBatch.self, from: legacyData)
        XCTAssertNil(decoded.capturedPlacement)
        XCTAssertNil(decoded.startPageIndex)
        XCTAssertNil(decoded.startSlotOffset)
        XCTAssertNil(decoded.legacySequenceOffset)
    }

    func testFreezingLegacyQueuePreservesContinuousMappingAndLocksPosition() {
        var firstElement = LabelElement.make(.text, index: 1)
        firstElement.content = "A"
        var secondElement = LabelElement.make(.text, index: 2)
        secondElement.content = "B"

        var document = LabelDocument.starter
        document.sheet.columns = 2
        document.sheet.rows = 2
        document.placement.selectedSlotIndices = []
        document.serial = SerialSettings(
            mode: .continuous,
            start: 10,
            step: 1,
            end: 10,
            repeatSets: 1,
            digits: 1,
            prefix: "",
            suffix: ""
        )
        document.printQueue = [
            PrintBatch(name: "A", quantity: 3, elements: [firstElement]),
            PrintBatch(name: "B", quantity: 3, elements: [secondElement])
        ]

        document.freezeLegacyPrintQueuePlacement()
        let firstID = document.printBatches[0].id
        let secondID = document.printBatches[1].id

        XCTAssertEqual(document.printBatches[0].startSlotOffset, 0)
        XCTAssertEqual(document.printBatches[1].startSlotOffset, 3)
        XCTAssertEqual(document.printBatches[1].legacySequenceOffset, 3)
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(
            (0..<4).map {
                document.renderPayload(slotIndex: $0, pageIndex: 0).batchID
            },
            [firstID, firstID, firstID, secondID]
        )
        XCTAssertEqual(
            document.renderPayload(slotIndex: 0, pageIndex: 1).batchID,
            secondID
        )
        XCTAssertEqual(
            document.renderPayload(slotIndex: 0, pageIndex: 1).context.serialValue,
            14
        )

        document.placement.selectedSlotIndices = [2]
        document.placement.fillDirection = .vertical
        XCTAssertEqual(
            (0..<4).map {
                document.renderPayload(slotIndex: $0, pageIndex: 0).batchID
            },
            [firstID, firstID, firstID, secondID]
        )
    }

    func testClampingAlsoUpdatesQueuedSnapshots() throws {
        var outside = LabelElement.make(.text, index: 1)
        outside.frame = RectMM(x: -50, y: 500, width: 500, height: 500)

        var document = LabelDocument.starter
        document.elements = [outside]
        document.printQueue = [
            PrintBatch(name: "Outside", quantity: 1, elements: [outside])
        ]
        document.clampElementsToSheet()

        let mainFrame = try XCTUnwrap(document.elements.first?.frame)
        let queuedFrame = try XCTUnwrap(document.printBatches.first?.elements.first?.frame)
        XCTAssertEqual(queuedFrame, mainFrame)
        XCTAssertGreaterThanOrEqual(queuedFrame.x, 0)
        XCTAssertGreaterThanOrEqual(queuedFrame.y, 0)
        XCTAssertLessThanOrEqual(queuedFrame.x + queuedFrame.width, document.sheet.labelWidthMM)
        XCTAssertLessThanOrEqual(queuedFrame.y + queuedFrame.height, document.sheet.labelHeightMM)
    }

    func testAllPagesPDFUsesQueuePageCount() throws {
        var firstElement = LabelElement.make(.text, index: 1)
        firstElement.content = "QUEUED DESIGN A"
        var secondElement = firstElement
        secondElement.id = UUID()
        secondElement.content = "QUEUED DESIGN B"

        var document = LabelDocument.starter
        document.elements = [firstElement]
        document.placement.selectedSlotIndices = []
        let firstQuantity = document.totalSlotCount / 2
        document.printQueue = [
            PrintBatch(name: "PDF batch A", quantity: firstQuantity, elements: [firstElement]),
            PrintBatch(
                name: "PDF batch B",
                quantity: document.totalSlotCount + 1 - firstQuantity,
                elements: [secondElement]
            )
        ]

        XCTAssertEqual(document.pageCount, 2)
        let data = PageRenderer.pdfDataAllPages(document: document)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
    }

    func testFontCollectionIncludesQueuedSnapshots() throws {
        let manager = NSFontManager.shared
        let customFamily = manager.availableFontFamilies.first { family -> Bool in
            guard let font = NSFont(name: family, size: 12)
                ?? manager.font(withFamily: family, traits: [], weight: 5, size: 12),
                let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
            else {
                return false
            }
            return !url.path.hasPrefix("/System/")
        }
        guard let customFamily else {
            throw XCTSkip("No non-system font installed on this machine")
        }

        var queuedElement = LabelElement.make(.text, index: 1)
        queuedElement.fontName = customFamily
        queuedElement.richTextRTF = nil

        var document = LabelDocument.starter
        document.elements = []
        document.printQueue = [
            PrintBatch(name: "Custom font", quantity: 1, elements: [queuedElement])
        ]

        XCTAssertFalse(FontEmbedder.collect(from: document).isEmpty)
    }
}

final class LabelGeometryTests: XCTestCase {
    func testCircleTextSafeFrameIsCenteredInscribedRectangle() {
        var circle = SheetTemplate.customDefault
        circle.shape = .circle
        circle.labelWidthMM = 42
        circle.labelHeightMM = 30

        let safe = circle.textSafeFrame
        XCTAssertEqual(safe.width, 42 / sqrt(2), accuracy: 0.000_001)
        XCTAssertEqual(safe.height, 30 / sqrt(2), accuracy: 0.000_001)
        XCTAssertEqual(safe.x, (42 - safe.width) / 2, accuracy: 0.000_001)
        XCTAssertEqual(safe.y, (30 - safe.height) / 2, accuracy: 0.000_001)
        XCTAssertEqual(safe.x + safe.width / 2, 21, accuracy: 0.000_001)
        XCTAssertEqual(safe.y + safe.height / 2, 15, accuracy: 0.000_001)

        circle.shape = .roundedRectangle
        XCTAssertEqual(
            circle.textSafeFrame,
            RectMM(x: 0, y: 0, width: 42, height: 30)
        )
    }

    func testCircleSheetClampPreservesFullCircularFlowInCurrentAndQueue() throws {
        var document = LabelDocument.starter
        document.sheet.shape = .circle
        document.sheet.labelWidthMM = 42
        document.sheet.labelHeightMM = 30

        var text = LabelElement.make(.text, index: 1)
        text.usesCircularTextFlow = true
        text.frame = RectMM(
            x: 4,
            y: 3,
            width: 12,
            height: 10
        )
        document.elements = [text]
        document.printQueue = [
            PrintBatch(name: "Queued", quantity: 1, elements: [text])
        ]

        document.clampElementsToSheet()

        let main = try XCTUnwrap(document.elements.first?.frame)
        let queued = try XCTUnwrap(document.printBatches.first?.elements.first?.frame)
        XCTAssertEqual(main, RectMM(x: 0, y: 0, width: 42, height: 30))
        XCTAssertEqual(queued, main)
    }
}

final class CircularTextLayoutTests: XCTestCase {
    func testCenteredCircularLayoutUsesWideEllipseChords() {
        let size = CGSize(width: mmToPoints(12), height: mmToPoints(12))
        let insets = CGSize(
            width: mmToPoints(textElementInsetXMM),
            height: mmToPoints(textElementInsetYMM)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(
            string: "(1)\n2026.07.30",
            attributes: [
                .font: NSFont.systemFont(ofSize: 3.5),
                .paragraphStyle: paragraph
            ]
        )

        let layout = CircularTextLayoutRenderer.makeLayout(
            attributed: attributed,
            size: size,
            insets: insets
        )
        let fragments = layout.lineFragmentRects

        XCTAssertEqual(layout.glyphRange.length, layout.layoutManager.numberOfGlyphs)
        XCTAssertGreaterThanOrEqual(fragments.count, 2)
        XCTAssertEqual(layout.usedRect.midY, size.height / 2, accuracy: 0.5)
        XCTAssertGreaterThan(
            fragments.map(\.width).max() ?? 0,
            mmToPoints((12 / sqrt(2)) - (2 * textElementInsetXMM)),
            "center lines should use more printable width than the old inset square"
        )
    }

    func testCircularLineFragmentBandsStayInsideInsetEllipse() {
        let size = CGSize(width: mmToPoints(42), height: mmToPoints(30))
        let insets = CGSize(width: 3, height: 2)
        let attributed = NSAttributedString(
            string: "Circular text flows through several lines without using square corners.",
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        let layout = CircularTextLayoutRenderer.makeLayout(
            attributed: attributed,
            size: size,
            insets: insets
        )
        let ellipse = CGRect(origin: .zero, size: size).insetBy(
            dx: insets.width,
            dy: insets.height
        )
        let radiusX = ellipse.width / 2
        let radiusY = ellipse.height / 2

        XCTAssertFalse(layout.lineFragmentRects.isEmpty)
        for fragment in layout.lineFragmentRects {
            for x in [fragment.minX, fragment.maxX] {
                for y in [fragment.minY, fragment.maxY] {
                    let normalized = pow((x - ellipse.midX) / radiusX, 2)
                        + pow((y - ellipse.midY) / radiusY, 2)
                    XCTAssertLessThanOrEqual(normalized, 1.02)
                }
            }
        }
    }

    func testCircularTextDrawsWideAndCenteredInVectorPDF() throws {
        var element = LabelElement.make(.text, index: 1)
        element.content = "WWWWWW"
        element.richTextRTF = nil
        element.fontSize = 4
        element.isBold = false
        element.textAlignment = .center
        element.frame = RectMM(x: 0, y: 0, width: 12, height: 12)
        element.usesCircularTextFlow = true

        var document = LabelDocument.starter
        document.sheet = SheetTemplate(
            id: "circle-pdf-test",
            name: "Circle PDF Test",
            pageWidthMM: 12,
            pageHeightMM: 12,
            columns: 1,
            rows: 1,
            labelWidthMM: 12,
            labelHeightMM: 12,
            horizontalGapMM: 0,
            verticalGapMM: 0,
            marginLeftMM: 0,
            marginTopMM: 0,
            shape: .circle,
            cornerRadiusMM: 6
        )
        document.elements = [element]
        document.dataTable = nil
        document.serial.end = document.serial.start
        document.serial.repeatSets = 1
        document.placement.selectedSlotIndices = []
        document.printQueue = nil

        let pdfData = try XCTUnwrap(PageRenderer.directPDFData(document: document, pageIndex: 0))
        let pdfDocument = try XCTUnwrap(PDFDocument(data: pdfData))
        let page = try XCTUnwrap(pdfDocument.page(at: 0))
        let pixels = 360
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let context = graphics.cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let pageBounds = page.bounds(for: .mediaBox)
        context.saveGState()
        context.scaleBy(
            x: CGFloat(pixels) / pageBounds.width,
            y: CGFloat(pixels) / pageBounds.height
        )
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        var ink: [(x: Int, y: Int)] = []
        for y in 0..<pixels {
            for x in 0..<pixels {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent < 0.45,
                   color.greenComponent < 0.45,
                   color.blueComponent < 0.45 {
                    ink.append((x, y))
                }
            }
        }

        XCTAssertGreaterThan(ink.count, 100)
        let minX = try XCTUnwrap(ink.map(\.x).min())
        let maxX = try XCTUnwrap(ink.map(\.x).max())
        let minY = try XCTUnwrap(ink.map(\.y).min())
        let maxY = try XCTUnwrap(ink.map(\.y).max())
        XCTAssertGreaterThan(
            maxX - minX,
            Int((12 / sqrt(2) - (2 * textElementInsetXMM)) / 12 * Double(pixels)),
            "printed ink should extend beyond the old square's usable width"
        )
        XCTAssertEqual(Double(minX + maxX) / 2, Double(pixels) / 2, accuracy: 6)
        XCTAssertEqual(Double(minY + maxY) / 2, Double(pixels) / 2, accuracy: 8)
    }

    func testCircularTextBackgroundUsesEllipseInOutputRenderer() throws {
        let pixels = 120
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let context = graphics.cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

        var element = LabelElement.make(.text, index: 1)
        element.content = ""
        element.richTextRTF = nil
        element.background = RGBAColor(red: 0.85, green: 0.1, blue: 0.1)
        element.usesCircularTextFlow = true
        PageRenderer.drawText(
            element: element,
            rect: CGRect(x: 0, y: 0, width: pixels, height: pixels),
            context: context,
            mergeContext: MergeContext(
                row: [:],
                serialValue: nil,
                rowNumber: 1,
                pageNumber: 1,
                slotNumber: 1,
                isActive: true
            ),
            serialSettings: .default,
            usesCircularFlow: true
        )

        let center = try XCTUnwrap(
            bitmap.colorAt(x: pixels / 2, y: pixels / 2)?.usingColorSpace(.deviceRGB)
        )
        let corner = try XCTUnwrap(
            bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(center.redComponent, 0.7)
        XCTAssertLessThan(center.greenComponent, 0.25)
        XCTAssertGreaterThan(corner.redComponent, 0.9)
        XCTAssertGreaterThan(corner.greenComponent, 0.9)
        XCTAssertGreaterThan(corner.blueComponent, 0.9)
    }
}

final class TextLayoutRegressionTests: XCTestCase {
    func testTrailingLineBreakDoesNotChangeRenderedStringOrHeight() {
        let context = MergeContext(
            row: [:],
            serialValue: 1,
            rowNumber: 1,
            pageNumber: 1,
            slotNumber: 1,
            isActive: true
        )
        var withoutTrailingBreak = LabelElement.make(.text, index: 1)
        withoutTrailingBreak.content = "A\nB"
        withoutTrailingBreak.richTextRTF = nil
        var withTrailingBreak = withoutTrailingBreak
        withTrailingBreak.content = "A\nB\n"

        let first = TextLayoutRenderer.attributedString(
            for: withoutTrailingBreak,
            context: context,
            serialSettings: .default
        )
        let second = TextLayoutRenderer.attributedString(
            for: withTrailingBreak,
            context: context,
            serialSettings: .default
        )
        let constraint = CGSize(width: 200, height: 200)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let firstHeight = first.boundingRect(with: constraint, options: options).height
        let secondHeight = second.boundingRect(with: constraint, options: options).height

        XCTAssertEqual(first.string, "A\nB")
        XCTAssertEqual(second.string, first.string)
        XCTAssertEqual(secondHeight, firstHeight, accuracy: 0.000_001)
        XCTAssertEqual(withTrailingBreak.content, "A\nB\n", "render cleanup must not mutate saved content")
    }
}
