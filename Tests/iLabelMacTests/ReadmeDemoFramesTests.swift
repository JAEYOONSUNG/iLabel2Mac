import AppKit
import SwiftUI
import XCTest
@testable import iLabelMac

/// Renders the README's macOS capture-queue walkthrough as PNG frames without
/// touching the screen: the real `ContentView` is hosted in an offscreen window
/// and driven through the store, one frame per step. `scripts/capture_readme_demo.sh`
/// stitches the frames into `docs/assets/capture-queue-workflow-macos.gif`.
///
/// Set `ILABEL_DEMO_FRAMES_DIR` to run; otherwise the test is skipped.
@MainActor
final class ReadmeDemoFramesTests: XCTestCase {
    private var window: NSWindow!
    private var hostingView: NSHostingView<AnyView>!
    private var framesDirectory: URL!
    private var manifest: [String] = []
    private var frameIndex = 0

    func testRenderCaptureQueueWalkthrough() throws {
        guard let path = ProcessInfo.processInfo.environment["ILABEL_DEMO_FRAMES_DIR"] else {
            throw XCTSkip("Set ILABEL_DEMO_FRAMES_DIR to render the README walkthrough frames")
        }
        framesDirectory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let store = DocumentStore(preferences: InMemoryPreferenceStore())
        store.appearanceMode = .light

        let suite = "iLabelStudio.ReadmeDemoFrames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SidebarSection.sheet.rawValue, forKey: "sidebar.section")
        defaults.set(ObjectInspectorSection.content.rawValue, forKey: "inspector.objectSection")
        defaults.set(PageInspectorSection.print.rawValue, forKey: "inspector.pageSection")
        defaults.set(false, forKey: "inspector.notesExpanded")
        defaults.set(false, forKey: "inspector.wifiExpanded")
        defaults.set(false, forKey: "inspector.snippetsExpanded")

        let size = NSSize(width: 1_512, height: 894)
        hostingView = NSHostingView(
            rootView: AnyView(
                ContentView(store: store)
                    .defaultAppStorage(defaults)
                    .preferredColorScheme(.light)
                    .frame(width: size.width, height: size.height)
            )
        )
        hostingView.appearance = NSAppearance(named: .aqua)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        settle()

        // 1. A new project opens on iLabel format 680 with an empty label.
        try frame("start", hold: 1.4)

        // 2. Pick another official sheet from the 1,006-format catalog.
        store.applyOfficialFormat(code: "237")
        XCTAssertEqual(store.document.sheet.columns, 3)
        store.updateDocument { $0.title = "Sample labels" }
        try frame("format", hold: 1.4)

        // 3. Add a text object and type a name plus a serial token.
        store.addElement(.text)
        let textID = try XCTUnwrap(store.selectedElementID)
        store.editingElementID = nil
        store.updateTextElement(id: textID, content: "Sample\n{{serial}}", richTextRTF: nil)
        try frame("text", hold: 1.6)

        // 4. Color and weight are per selection: only the first line turns blue and bold.
        var lines: [(String, NSColor, Bool, CGFloat)] = [
            ("Sample", .demoBlue, true, 18),
            ("\n{{serial}}", .black, false, 14),
        ]
        store.updateTextElement(id: textID, content: joined(lines), richTextRTF: try rtf(lines))
        try frame("color", hold: 1.6)

        // 5. Emoji and symbols are ordinary characters on the label.
        lines = [
            ("🧪 Sample", .demoBlue, true, 18),
            ("\n{{serial}}", .black, false, 14),
            ("\n−20 °C · {{date}}", .demoGray, false, 7),
        ]
        store.updateTextElement(id: textID, content: joined(lines), richTextRTF: try rtf(lines))
        try frame("emoji", hold: 1.8)

        // 5. Eight labels: numbers 1–4, printed twice.
        store.updateDocument { document in
            document.serial.end = 4
            document.serial.repeatSets = 2
        }
        try frame("quantity", hold: 1.6)

        // 6. Page preview shows the eight cells the run will occupy.
        store.canvasMode = .page
        try frame("page", hold: 1.6)

        // 7. Capture the current setup.
        store.enqueueCurrentLabel()
        XCTAssertEqual(store.document.printBatches.count, 1)
        try frame("capture-1", hold: 1.8)

        // 8. Click an empty cell to stage the next run.
        store.selectPlacementStart(at: 12)
        try frame("stage", hold: 1.4)

        // 9. Change the artwork and the quantity for the second run.
        lines = [
            ("🔥 Control", .demoRed, true, 18),
            ("\n{{serial}}", .black, false, 14),
            ("\n37 °C · {{date}}", .demoGray, false, 7),
        ]
        store.updateTextElement(id: textID, content: joined(lines), richTextRTF: try rtf(lines))
        store.updateDocument { document in
            document.serial.end = 3
            document.serial.repeatSets = 1
        }
        try frame("second-design", hold: 1.6)

        // 10. Capture it too: the queue now holds two designs.
        store.enqueueCurrentLabel()
        XCTAssertEqual(store.document.printBatches.count, 2)
        XCTAssertEqual(store.document.queuedLabelCount, 11)
        try frame("capture-2", hold: 1.8)

        // 11. Reposition the second run: pick it up, then click another empty cell.
        let second = try XCTUnwrap(store.document.printBatches.last)
        store.beginMovingPrintBatch(id: second.id)
        try frame("move", hold: 1.4)
        store.selectPlacementStart(at: 18)
        XCTAssertNil(store.printBatchMoveSession)
        try frame("moved", hold: 2.4)

        try (manifest.joined(separator: "\n") + "\n")
            .write(to: framesDirectory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
    }

    private func frame(_ name: String, hold: Double) throws {
        settle()
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        frameIndex += 1
        let file = String(format: "%02d-%@.png", frameIndex, name)
        try png.write(to: framesDirectory.appendingPathComponent(file), options: .atomic)
        manifest.append("file '\(file)'")
        manifest.append("duration \(hold)")
    }

    private func joined(_ runs: [(String, NSColor, Bool, CGFloat)]) -> String {
        runs.map(\.0).joined()
    }

    private func rtf(_ runs: [(String, NSColor, Bool, CGFloat)]) throws -> Data {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSMutableAttributedString()
        for (string, color, bold, size) in runs {
            let font = PageRenderer.nsFont(name: "Arial", size: size, isBold: bold, isItalic: false)
            text.append(NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }
        return try XCTUnwrap(text.rtf(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
    }
}

private extension NSColor {
    static let demoBlue = NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.86, alpha: 1)
    static let demoRed = NSColor(calibratedRed: 0.82, green: 0.15, blue: 0.13, alpha: 1)
    static let demoGray = NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.38, alpha: 1)
}
