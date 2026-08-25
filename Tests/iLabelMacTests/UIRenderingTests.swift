import AppKit
import SwiftUI
import XCTest
@testable import iLabelMac

@MainActor
final class UIRenderingTests: XCTestCase {
    func testMainEditorRendersWithPopulatedPrintQueue() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["ILABEL_UI_SNAPSHOT_PATH"] else {
            throw XCTSkip("Set ILABEL_UI_SNAPSHOT_PATH to generate the full editor snapshot")
        }

        let store = DocumentStore()
        store.addElement(.text)
        let elementID = try XCTUnwrap(store.selectedElementID)

        store.updateTextElement(
            id: elementID,
            content: "pEcCas-ptet\nMCv0.0.6.\nAac142\n2026.07.30",
            richTextRTF: nil
        )
        store.document.serial.end = 12
        store.enqueueCurrentLabel()
        store.updateTextElement(
            id: elementID,
            content: "Second label\nDifferent value\nB-204",
            richTextRTF: nil
        )
        store.document.serial.start = 101
        store.document.serial.end = 112
        store.selectPlacementStart(at: 14)

        if ProcessInfo.processInfo.environment["ILABEL_UI_MODE"] == "page" {
            store.canvasMode = .page
        }

        XCTAssertEqual(store.document.printBatches.count, 1)
        XCTAssertEqual(store.document.queuedLabelCount, 12)
        let draftPlan = try XCTUnwrap(store.pendingDraftPlan)
        XCTAssertNil(store.document.firstPlacementConflict(for: draftPlan))
        XCTAssertEqual(
            store.document.draftPreviewSlotIndices(
                pageIndex: 0,
                plan: draftPlan
            ),
            Array(14..<26)
        )

        let width = Double(ProcessInfo.processInfo.environment["ILABEL_UI_WIDTH"] ?? "") ?? 1_800
        let height = Double(ProcessInfo.processInfo.environment["ILABEL_UI_HEIGHT"] ?? "") ?? 1_150
        let size = NSSize(width: width, height: height)
        let requestedScheme: ColorScheme? = switch ProcessInfo.processInfo.environment["ILABEL_UI_SCHEME"] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
        let defaultsSuite = "iLabelStudio.UIRenderingTests.\(UUID().uuidString)"
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        testDefaults.set(
            ProcessInfo.processInfo.environment["ILABEL_UI_SIDEBAR_SECTION"]
                ?? SidebarSection.sheet.rawValue,
            forKey: "sidebar.section"
        )
        testDefaults.set(
            ProcessInfo.processInfo.environment["ILABEL_UI_OBJECT_SECTION"]
                ?? ObjectInspectorSection.content.rawValue,
            forKey: "inspector.objectSection"
        )
        testDefaults.set(
            ProcessInfo.processInfo.environment["ILABEL_UI_PAGE_SECTION"]
                ?? PageInspectorSection.print.rawValue,
            forKey: "inspector.pageSection"
        )
        testDefaults.set(false, forKey: "inspector.notesExpanded")
        testDefaults.set(false, forKey: "inspector.wifiExpanded")
        testDefaults.set(false, forKey: "inspector.snippetsExpanded")
        defer { testDefaults.removePersistentDomain(forName: defaultsSuite) }
        let hostingView = NSHostingView(
            rootView: ContentView(store: store)
                .defaultAppStorage(testDefaults)
                .preferredColorScheme(requestedScheme)
                .frame(width: size.width, height: size.height)
        )
        if requestedScheme == .light {
            hostingView.appearance = NSAppearance(named: .aqua)
        } else if requestedScheme == .dark {
            hostingView.appearance = NSAppearance(named: .darkAqua)
        }
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 50_000)
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
