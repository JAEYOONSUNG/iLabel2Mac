import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let defaultOfficialFormatCode = SheetTemplate.default680.id
private let cachedPrintAutomationKey = "iLabel2Mac.cachedPrintAutomation"
private let cachedLastSheetSetupKey = "iLabel2Mac.cachedLastSheetSetup"
private let cachedQuickTextPresetsKey = "iLabel2Mac.cachedQuickTextPresets"
private let cachedAppearanceModeKey = "iLabel2Mac.cachedAppearanceMode"
let quickTextInsertNotification = Notification.Name("iLabel2Mac.quickTextInsert")
let textStyleActionNotification = Notification.Name("iLabel2Mac.textStyleAction")
let showEmojiPickerNotification = Notification.Name("iLabel2Mac.showEmojiPicker")

/// Persistence facade: UserDefaults in the app, an in-memory store under
/// XCTest. Store instances must start canonical in tests — persisting the
/// last-used sheet through shared UserDefaults let one test's geometry edit
/// leak into every store the suite created afterwards.
protocol PreferenceStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func stringArray(forKey key: String) -> [String]?
    func string(forKey key: String) -> String?
}

extension UserDefaults: PreferenceStoring {}

final class InMemoryPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }

    func set(_ value: Any?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }

    func string(forKey key: String) -> String? { values[key] as? String }
}

enum TextStyleAction: Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case superscript
    case subscriptText
    case fontFamily(String)
    case fontSize(Double)
    case textColor(RGBAColor)
    case highlightColor(RGBAColor)
    case clearFormatting
}

/// Carries a style action to the active inline editor. Notification posting
/// is synchronous, so `handled` reports back whether the editor consumed the
/// action (e.g. applied it to a selection); if not, the store falls through
/// to the element-wide behavior.
final class TextStyleActionRequest {
    let action: TextStyleAction
    var handled = false

    init(_ action: TextStyleAction) {
        self.action = action
    }
}

enum RichTextFormatting {
    static let superscriptAttribute = NSAttributedString.Key.superscript

    static func applyingAdvancedAction(
        _ action: TextStyleAction,
        to attributes: [NSAttributedString.Key: Any],
        baseFont: NSFont,
        baseForeground: NSColor,
        alignment: NSTextAlignment,
        baseUnderline: Bool
    ) -> [NSAttributedString.Key: Any] {
        var updated = attributes
        switch action {
        case .strikethrough:
            let current = integerValue(attributes[.strikethroughStyle])
            updated[.strikethroughStyle] = current == 0
                ? NSUnderlineStyle.single.rawValue
                : 0
        case .superscript:
            let current = integerValue(attributes[superscriptAttribute])
            updated[superscriptAttribute] = current == 1 ? 0 : 1
        case .subscriptText:
            let current = integerValue(attributes[superscriptAttribute])
            updated[superscriptAttribute] = current == -1 ? 0 : -1
        case .highlightColor(let color):
            if color.alpha <= 0.001 {
                updated.removeValue(forKey: .backgroundColor)
            } else {
                updated[.backgroundColor] = color.nsColor
            }
        case .clearFormatting:
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            updated = [
                .font: baseFont,
                .foregroundColor: baseForeground,
                .paragraphStyle: paragraph,
                .underlineStyle: baseUnderline ? NSUnderlineStyle.single.rawValue : 0
            ]
        default:
            break
        }
        return updated
    }

    static func rewriting(
        _ action: TextStyleAction,
        rtfData: Data?,
        content: String,
        baseFont: NSFont,
        baseForeground: NSColor,
        alignment: NSTextAlignment,
        baseUnderline: Bool
    ) -> Data? {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let fallbackAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseForeground,
            .paragraphStyle: paragraph,
            .underlineStyle: baseUnderline ? NSUnderlineStyle.single.rawValue : 0
        ]
        let source: NSAttributedString
        if let decoded = RTFDecodeCache.decode(rtfData), decoded.string == content {
            source = decoded
        } else {
            source = NSAttributedString(string: content, attributes: fallbackAttributes)
        }

        let mutable = NSMutableAttributedString(attributedString: source)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return rtfData }
        source.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let updated = applyingAdvancedAction(
                action,
                to: attributes,
                baseFont: baseFont,
                baseForeground: baseForeground,
                alignment: alignment,
                baseUnderline: baseUnderline
            )
            mutable.setAttributes(updated, range: range)
        }
        return mutable.rtf(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) ?? rtfData
    }

    private static func integerValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int ?? 0
    }
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var document: LabelDocument = .starter
    @Published var previewDocument: LabelDocument = .starter
    @Published var selectedElementID: UUID?
    @Published var editingElementID: UUID?
    @Published var canvasMode: CanvasMode = .label
    @Published var currentPageIndex = 0
    @Published private(set) var pendingDraftPageIndex: Int? = 0
    @Published var statusMessage = "Ready"
    @Published var projectURL: URL?
    @Published var formatSearchText = ""
    @Published var selectedFamilyFilter: ProductFamily?
    @Published var quickTextPresets: [String] = []
    @Published var newQuickTextPreset = ""
    @Published var currentWiFiSSID = ""
    @Published var wifiTestStatus = "Not tested"
    @Published var captureQueueIssue: String?
    @Published var appearanceMode: AppAppearanceMode = .system {
        didSet { persistAppearanceMode() }
    }

    /// Bookkeeping while a captured batch is checked out of the queue for
    /// editing: the next capture puts it back with the same identity, queue
    /// position, and sheet slots. Mirrors the desktop edition.
    struct PrintBatchEditSession {
        let batchID: UUID
        let batchName: String
        let queueIndex: Int
        let startPageIndex: Int
        let startSlotOffset: Int
        /// Snapshot from before the edit began, so Cancel restores the queue untouched.
        let previousDocument: LabelDocument
        let previousPendingDraftPageIndex: Int?
        let previousCurrentPageIndex: Int
    }

    @Published private(set) var printBatchEditSession: PrintBatchEditSession?

    /// Armed while the user is choosing a new sheet position for a captured
    /// batch: the next slot click moves that batch instead of staging the
    /// draft's start position. Mirrors the desktop edition.
    struct PrintBatchMoveSession {
        let batchID: UUID
        let batchName: String
    }

    @Published private(set) var printBatchMoveSession: PrintBatchMoveSession?

    let officialFormats: [OfficialFormatDefinition]
    private var previewRefreshWorkItem: DispatchWorkItem?
    private var lastPreviewRefreshAt = Date.distantPast
    private let previewRefreshInterval: TimeInterval = 0.12

    // Undo/redo history of whole-document snapshots. Rapid edits that share a
    // coalescing key within `undoCoalescingInterval` (a drag, a typing burst)
    // collapse into a single undo step.
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [LabelDocument] = []
    private var redoStack: [LabelDocument] = []
    private var lastUndoCoalescingKey: String?
    private var lastUndoTime = Date.distantPast
    private let undoCoalescingInterval: TimeInterval = 1.0
    private let maxUndoDepth = 80
    // Serializes Wi-Fi print transactions: a second print must wait for the
    // first one's switch → transmit → restore cycle to finish.
    private var wifiAutomationTask: Task<Void, Never>?

    /// Snapshot of the most recently used label stock, so a new session (or
    /// New) starts on the size the user actually works with instead of the
    /// factory default. A remembered official format restores its full
    /// metadata; a custom/preset sheet restores its raw geometry.
    private struct LastSheetSetup: Codable {
        var formatCode: String?
        var sheet: SheetTemplate
    }

    private let preferences: PreferenceStoring

    init(preferences: PreferenceStoring? = nil) {
        self.preferences = preferences
            ?? (NSClassFromString("XCTestCase") != nil
                ? InMemoryPreferenceStore()
                : UserDefaults.standard)
        officialFormats = OfficialFormatCatalog.load()
        applyStartupSheetSetup()
        document.printAutomation = loadCachedPrintAutomation()
        quickTextPresets = loadCachedQuickTextPresets()
        appearanceMode = loadAppearanceMode()
        previewDocument = document
        selectedElementID = document.elements.first?.id
        editingElementID = nil
        refreshCurrentWiFiSSID()
    }

    var selectedElement: LabelElement? {
        guard let selectedElementID else { return nil }
        return document.elements.first(where: { $0.id == selectedElementID })
    }

    var editingElement: LabelElement? {
        guard let editingElementID else { return nil }
        return document.elements.first(where: { $0.id == editingElementID })
    }

    /// Once captures exist, one blank staging page remains navigable after the
    /// last printed page so a full sheet never blocks the next capture.
    var navigationPageCount: Int {
        guard document.hasQueuedLabels, document.pageCount < Int.max else {
            return document.pageCount
        }
        return document.pageCount + 1
    }

    var isCaptureStagingPage: Bool {
        document.hasQueuedLabels && currentPageIndex == document.pageCount
    }

    var pendingDraftPlan: DraftPlacementPlan? {
        guard let pendingDraftPageIndex else { return nil }
        return document.draftPlacementPlan(
            startPageIndex: pendingDraftPageIndex
        )
    }

    var pendingDraftConflict: PrintPlacementConflict? {
        guard document.hasQueuedLabels, let pendingDraftPlan else {
            return nil
        }
        return document.firstPlacementConflict(for: pendingDraftPlan)
    }

    var pendingDraftIssueMessage: String? {
        guard let pendingDraftConflict else { return nil }
        return placementConflictMessage(pendingDraftConflict)
    }

    var canCaptureCurrentLabel: Bool {
        guard !document.elements.isEmpty else { return false }
        if document.hasQueuedLabels && pendingDraftPageIndex == nil {
            return false
        }
        return pendingDraftConflict == nil
    }

    private func clampCurrentPageIndex() {
        currentPageIndex = min(
            max(0, currentPageIndex),
            max(0, navigationPageCount - 1)
        )
    }

    var currentFormat: OfficialFormatDefinition? {
        guard let code = document.formatCode else { return nil }
        return officialFormats.first(where: { $0.code == code })
    }

    var filteredFormats: [OfficialFormatDefinition] {
        let query = formatSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return officialFormats.filter { format in
            let familyMatches = selectedFamilyFilter == nil || format.family == selectedFamilyFilter
            guard familyMatches else { return false }

            guard !query.isEmpty else { return true }
            let haystack = [
                format.code,
                format.name,
                format.family.label,
                format.sizeSummary,
                format.officialType
            ].joined(separator: " ").lowercased()
            return haystack.contains(query.lowercased())
        }
    }

    private func recordUndo(coalescingKey: String?) {
        let now = Date()
        let coalesce = coalescingKey != nil
            && coalescingKey == lastUndoCoalescingKey
            && now.timeIntervalSince(lastUndoTime) < undoCoalescingInterval
        lastUndoCoalescingKey = coalescingKey
        lastUndoTime = now
        guard !coalesce else { return }

        undoStack.append(document)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst(undoStack.count - maxUndoDepth)
        }
        redoStack.removeAll()
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoCoalescingKey = nil
        refreshUndoState()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        applyRestoredDocument(previous)
        statusMessage = "Undo"
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        applyRestoredDocument(next)
        statusMessage = "Redo"
    }

    private func applyRestoredDocument(_ restored: LabelDocument) {
        lastUndoCoalescingKey = nil
        let didRestoreQueueMutation =
            document.printBatches != restored.printBatches
        document = restored
        document.clampElementsToSheet()
        if didRestoreQueueMutation {
            pendingDraftPageIndex = document.hasQueuedLabels ? nil : 0
        } else if !document.hasQueuedLabels,
                  pendingDraftPageIndex == nil {
            pendingDraftPageIndex = 0
        }
        if let selectedElementID, !document.elements.contains(where: { $0.id == selectedElementID }) {
            self.selectedElementID = document.elements.first?.id
        }
        editingElementID = nil
        printBatchEditSession = nil
        printBatchMoveSession = nil
        persistPrintAutomationCache(document.printAutomation)
        clampCurrentPageIndex()
        refreshUndoState()
        schedulePreviewRefresh(immediate: true)
    }

    func updateSheet(_ edit: (inout SheetTemplate) -> Void) {
        guard !document.hasQueuedLabels else {
            statusMessage = "Reset the capture queue before changing sheet geometry"
            return
        }
        recordUndo(coalescingKey: "sheet")
        edit(&document.sheet)
        document.formatCode = nil
        document.formatFamily = nil
        document.formatSourceURL = nil
        document.formatPDFTemplateURL = nil
        document.clampElementsToSheet()
        persistLastSheetSetup()
        clampCurrentPageIndex()
        schedulePreviewRefresh()
    }

    func updateDocument(coalescingKey: String? = "document", _ edit: (inout LabelDocument) -> Void) {
        recordUndo(coalescingKey: coalescingKey)
        edit(&document)
        document.clampElementsToSheet()
        persistPrintAutomationCache(document.printAutomation)
        // No refreshCurrentWiFiSSID() here: it spawns `networksetup`
        // synchronously (tens–hundreds of ms) and this method runs on every
        // keystroke of the title/notes/Wi-Fi text fields — it froze the UI.
        // The SSID label refreshes where it matters: save, test, and print.
        clampCurrentPageIndex()
        schedulePreviewRefresh()
    }

    func updateSelected(_ edit: (inout LabelElement) -> Void) {
        guard let selectedElementID else {
            return
        }
        updateElement(id: selectedElementID, edit)
    }

    func updateElement(id: UUID, _ edit: (inout LabelElement) -> Void) {
        guard let index = document.elements.firstIndex(where: { $0.id == id }) else {
            return
        }
        recordUndo(coalescingKey: "elem:\(id.uuidString)")
        edit(&document.elements[index])
        document.elements[index].frame = document.elements[index].frame.clamped(
            maxWidth: document.sheet.labelWidthMM,
            maxHeight: document.sheet.labelHeightMM
        )
        if document.sheet.shape == .circle,
           document.elements[index].type == .text,
           document.elements[index].usesCircularTextFlow == true {
            document.elements[index].frame = RectMM(
                x: 0,
                y: 0,
                width: document.sheet.labelWidthMM,
                height: document.sheet.labelHeightMM
            )
        }
        schedulePreviewRefresh()
    }

    /// Applies the inline editor's plain text and rich-text payload in a
    /// single edit, so observers never see `content` published without its
    /// matching `richTextRTF` (or vice versa).
    func updateTextElement(id: UUID, content: String, richTextRTF: Data?) {
        updateElement(id: id) { element in
            element.content = content
            element.richTextRTF = richTextRTF
        }
    }

    func selectElement(_ id: UUID?, beginEditing: Bool = false) {
        selectedElementID = id
        if beginEditing,
           let id,
           let element = document.elements.first(where: { $0.id == id }),
           element.type == .text {
            editingElementID = id
            statusMessage = "Editing text"
        } else if editingElementID != id {
            editingElementID = nil
        }
    }

    func finishInlineEditing() {
        editingElementID = nil
        schedulePreviewRefresh(immediate: true)
    }

    func insertQuickTextPreset(_ preset: String) {
        guard !preset.isEmpty else { return }
        guard let selectedElement,
              selectedElement.type == .text
                || selectedElement.type == .qrCode
                || selectedElement.type == .code128 else {
            statusMessage = "Select text, QR, or barcode content first"
            return
        }
        if canvasMode == .label,
           selectedElement.type == .text,
           editingElementID == selectedElement.id {
            NotificationCenter.default.post(name: quickTextInsertNotification, object: preset)
        } else {
            updateSelected { element in
                element.content += preset
            }
        }
        statusMessage = "Inserted preset: \(preset)"
    }

    func addQuickTextPreset() {
        let trimmed = newQuickTextPreset.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !quickTextPresets.contains(trimmed) else {
            newQuickTextPreset = ""
            return
        }
        quickTextPresets.append(trimmed)
        quickTextPresets.sort()
        persistQuickTextPresets()
        newQuickTextPreset = ""
        statusMessage = "Saved preset: \(trimmed)"
    }

    func saveSelectedContentAsPreset() {
        guard let selectedElement, selectedElement.type == .text else { return }
        let trimmed = selectedElement.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        newQuickTextPreset = trimmed
        addQuickTextPreset()
    }

    func removeQuickTextPreset(_ preset: String) {
        quickTextPresets.removeAll { $0 == preset }
        persistQuickTextPresets()
        statusMessage = "Removed preset: \(preset)"
    }

    func savePrintAutomationSettings() {
        persistPrintAutomationCache(document.printAutomation)
        refreshCurrentWiFiSSID()
        wifiTestStatus = "Saved"
        statusMessage = "Saved Wi-Fi print settings"
    }

    func testPrintAutomationConnection() {
        let settings = document.printAutomation
        wifiTestStatus = "Testing..."
        Task {
            do {
                let session = try await WiFiPrintAutomation.prepare(
                    settings: settings,
                    discoveryTimeoutSeconds: 15
                ) { message in
                    Task { @MainActor [weak self] in
                        self?.wifiTestStatus = message
                    }
                }
                await MainActor.run {
                    refreshCurrentWiFiSSID()
                    wifiTestStatus = settings.enabled ? "Connected to \(currentWiFiSSID)" : "Wi-Fi print disabled"
                    statusMessage = settings.enabled ? "Connected to printer Wi-Fi" : "Wi-Fi print is disabled"
                }
                if let session, settings.reconnectToPreviousWiFi {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    try? await session.restore()
                    await MainActor.run {
                        refreshCurrentWiFiSSID()
                        wifiTestStatus = "Restored to \(currentWiFiSSID)"
                        statusMessage = "Wi-Fi test finished and restored previous network"
                    }
                }
            } catch {
                await MainActor.run {
                    refreshCurrentWiFiSSID()
                    wifiTestStatus = "Failed: \(error.localizedDescription)"
                    statusMessage = "Wi-Fi test failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func autofillPrintAutomationSettings() {
        updateDocument { document in
            document.printAutomation.wifiService = "Wi-Fi"
            if let detected = WiFiPrintAutomation.autoDetectedPrinterSSID() {
                document.printAutomation.printerSSID = detected
            }
        }
        refreshCurrentWiFiSSID()
        wifiTestStatus = document.printAutomation.printerSSID.isEmpty ? "No printer SSID auto-detected" : "Auto-filled \(document.printAutomation.printerSSID)"
        statusMessage = wifiTestStatus
    }

    func activatePrimaryTextElement() {
        if let selectedElement, selectedElement.type == .text {
            selectElement(selectedElement.id, beginEditing: true)
            return
        }

        if let firstText = document.elements.first(where: { $0.type == .text }) {
            selectElement(firstText.id, beginEditing: true)
            return
        }

        addElement(.text)
    }

    func applyTextStyleAction(_ action: TextStyleAction) {
        if editingElementID != nil {
            let request = TextStyleActionRequest(action)
            NotificationCenter.default.post(name: textStyleActionNotification, object: request)
            // The editor declines font/size actions when nothing is selected
            // (and is absent entirely in that window state), in which case the
            // action applies element-wide below.
            if request.handled {
                return
            }
        }

        guard let selectedElement, selectedElement.type == .text else { return }
        updateSelected { element in
            switch action {
            case .bold:
                element.isBold.toggle()
            case .italic:
                element.isItalic.toggle()
            case .underline:
                element.isUnderline.toggle()
            case .strikethrough, .superscript, .subscriptText, .highlightColor:
                element.richTextRTF = RichTextFormatting.rewriting(
                    action,
                    rtfData: element.richTextRTF,
                    content: element.content,
                    baseFont: resolvedNSFont(
                        name: element.fontName,
                        size: CGFloat(element.fontSize),
                        isBold: element.isBold,
                        isItalic: element.isItalic
                    ),
                    baseForeground: element.foreground.nsColor,
                    alignment: element.textAlignment.nsTextAlignment,
                    baseUnderline: element.isUnderline
                )
            case .fontFamily(let name):
                element.fontName = name
                // Rich-text runs carry their own family (per-selection fonts),
                // so an element-wide change must rewrite them too — otherwise
                // it only affects newly typed characters.
                element.richTextRTF = LabelElement.rewritingFontFamily(of: element.richTextRTF, to: name)
            case .fontSize(let size):
                // Runs carry their own size too; scale them proportionally so
                // a mixed-size design keeps its ratios when resized as a whole.
                let ratio = size / max(element.fontSize, 0.1)
                element.fontSize = size
                element.richTextRTF = LabelElement.scalingFontSizes(of: element.richTextRTF, by: ratio)
            case .textColor(let color):
                // Element-wide means "repaint everything": rewrite the runs too,
                // which also drops any per-selection colors, so the element is
                // back to a single color the inspector fully controls.
                element.foreground = color
                element.richTextRTF = LabelElement.rewritingForegroundColor(of: element.richTextRTF, to: color)
            case .clearFormatting:
                element.isBold = false
                element.isItalic = false
                element.isUnderline = false
                element.richTextRTF = RichTextFormatting.rewriting(
                    action,
                    rtfData: element.richTextRTF,
                    content: element.content,
                    baseFont: resolvedNSFont(
                        name: element.fontName,
                        size: CGFloat(element.fontSize),
                        isBold: false,
                        isItalic: false
                    ),
                    baseForeground: element.foreground.nsColor,
                    alignment: element.textAlignment.nsTextAlignment,
                    baseUnderline: false
                )
            }
        }
    }

    func showEmojiPicker() {
        guard let selectedElement, selectedElement.type == .text else { return }
        canvasMode = .label
        selectElement(selectedElement.id, beginEditing: true)
        statusMessage = "Emoji & Symbols"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: showEmojiPickerNotification, object: nil)
        }
    }

    func applySelectedTextOrientation(vertical: Bool) {
        guard let selectedElement, selectedElement.type == .text else { return }
        updateSelected { element in
            if vertical {
                element.usesCircularTextFlow = false
                let widthFactor: Double
                let heightFactor: Double
                switch document.sheet.shape {
                case .circle:
                    widthFactor = 0.30
                    heightFactor = 0.88
                case .capsule:
                    widthFactor = 0.22
                    heightFactor = 0.82
                case .rectangle, .roundedRectangle:
                    widthFactor = 0.28
                    heightFactor = 0.84
                }

                let targetWidth = max(4.5, document.sheet.labelWidthMM * widthFactor)
                let targetHeight = max(10, document.sheet.labelHeightMM * heightFactor)
                element.frame.width = targetWidth
                element.frame.height = targetHeight
                element.frame.x = max(0, (document.sheet.labelWidthMM - targetWidth) / 2)
                element.frame.y = max(0, (document.sheet.labelHeightMM - targetHeight) / 2)
            } else if element.verticalTextLayout == true {
                let targetWidth: Double
                let targetHeight: Double
                switch document.sheet.shape {
                case .circle:
                    targetWidth = document.sheet.labelWidthMM
                    targetHeight = document.sheet.labelHeightMM
                    element.usesCircularTextFlow = true
                case .capsule:
                    targetWidth = max(10, document.sheet.labelWidthMM * 0.90)
                    targetHeight = max(8, document.sheet.labelHeightMM * 0.82)
                    element.usesCircularTextFlow = false
                case .rectangle, .roundedRectangle:
                    targetWidth = max(10, document.sheet.labelWidthMM * 0.90)
                    targetHeight = max(8, document.sheet.labelHeightMM * 0.78)
                    element.usesCircularTextFlow = false
                }
                element.frame = RectMM(
                    x: max(0, (document.sheet.labelWidthMM - targetWidth) / 2),
                    y: max(0, (document.sheet.labelHeightMM - targetHeight) / 2),
                    width: targetWidth,
                    height: targetHeight
                )
            }

            element.rotation = 0
            element.verticalTextLayout = vertical
            element.textAlignment = .center
        }
        statusMessage = vertical ? "Applied vertical stacked text layout" : "Applied horizontal text layout"
    }

    private func ensureLegacyQueueIsFrozen() {
        guard document.printBatches.contains(where: {
            $0.capturedPlacement == nil
        }) else { return }
        updateDocument(coalescingKey: nil) { document in
            document.freezeLegacyPrintQueuePlacement()
        }
    }

    private func placementConflictMessage(
        _ conflict: PrintPlacementConflict
    ) -> String {
        let coordinate = document.coordinateLabel(for: conflict.slotIndex)
        return "Page \(conflict.pageIndex + 1) \(coordinate) is already fixed by “\(conflict.existingBatchName)”. Choose an empty start position for the next capture."
    }

    private func updatePendingDraftStatus(successMessage: String) {
        if let pendingDraftIssueMessage {
            // This conflict is derived from the live Numbering/CSV quantity,
            // so let the computed message update immediately when those
            // inputs change instead of caching a stale error string.
            captureQueueIssue = nil
            statusMessage = pendingDraftIssueMessage
        } else {
            captureQueueIssue = nil
            statusMessage = successMessage
        }
    }

    func selectPlacementStart(at slotIndex: Int) {
        ensureLegacyQueueIsFrozen()
        let total = document.totalSlotCount
        guard slotIndex >= 0, slotIndex < total else { return }
        if let session = printBatchMoveSession {
            repositionPrintBatch(session, to: slotIndex)
            return
        }
        if document.hasQueuedLabels {
            let committed = document.renderPayload(
                slotIndex: slotIndex,
                pageIndex: currentPageIndex
            )
            if committed.context.isActive, committed.batchID != nil {
                let coordinate = document.coordinateLabel(for: slotIndex)
                let message = "Page \(currentPageIndex + 1) \(coordinate) is already captured. Choose an empty start position."
                captureQueueIssue = message
                statusMessage = message
                return
            }
        }
        updateDocument { document in
            document.placement.selectedSlotIndices = document.slotIndicesStarting(
                at: slotIndex,
                fillDirection: document.placement.fillDirection
            )
        }
        pendingDraftPageIndex = currentPageIndex
        updatePendingDraftStatus(
            successMessage: "Next capture starts at \(document.coordinateLabel(for: slotIndex))"
        )
        schedulePreviewRefresh(immediate: true)
    }

    func selectPlacementRect(from startSlot: Int, to endSlot: Int) {
        ensureLegacyQueueIsFrozen()
        if let session = printBatchMoveSession {
            repositionPrintBatch(session, to: min(startSlot, endSlot))
            return
        }
        let columns = document.sheet.columns
        let rows = document.sheet.rows
        guard columns > 0, rows > 0 else { return }

        let startRow = startSlot / columns
        let startColumn = startSlot % columns
        let endRow = endSlot / columns
        let endColumn = endSlot % columns

        let rowRange = min(startRow, endRow)...max(startRow, endRow)
        let columnRange = min(startColumn, endColumn)...max(startColumn, endColumn)

        var indices: [Int] = []
        for row in rowRange {
            for column in columnRange {
                indices.append((row * columns) + column)
            }
        }

        updateDocument { document in
            document.placement.selectedSlotIndices = indices
        }
        pendingDraftPageIndex = currentPageIndex
        if let first = indices.first, let last = indices.last {
            updatePendingDraftStatus(
                successMessage: "Next capture area: \(document.coordinateLabel(for: first)) to \(document.coordinateLabel(for: last))"
            )
        } else {
            updatePendingDraftStatus(
                successMessage: "Selected \(indices.count) slot(s) for the next capture"
            )
        }
        schedulePreviewRefresh(immediate: true)
    }

    func clearPlacementSelection() {
        ensureLegacyQueueIsFrozen()
        updateDocument { document in
            document.placement.selectedSlotIndices = []
        }
        pendingDraftPageIndex = currentPageIndex
        updatePendingDraftStatus(
            successMessage: "Next capture area reset to the full page"
        )
        schedulePreviewRefresh(immediate: true)
    }

    func updatePlacementFillDirection(_ newDirection: PlacementFillDirection) {
        ensureLegacyQueueIsFrozen()
        let oldPlacement = document.placement
        guard oldPlacement.fillDirection != newDirection else { return }
        let currentFirstSlot = document.orderedSlotIndices(for: oldPlacement).first
        let isStartSelection: Bool
        if let currentFirstSlot, !oldPlacement.selectedSlotIndices.isEmpty {
            isStartSelection = Set(oldPlacement.selectedSlotIndices) == Set(
                document.slotIndicesStarting(
                    at: currentFirstSlot,
                    fillDirection: oldPlacement.fillDirection
                )
            )
        } else {
            isStartSelection = false
        }

        updateDocument { document in
            document.placement.fillDirection = newDirection
            if isStartSelection, let currentFirstSlot {
                document.placement.selectedSlotIndices = document.slotIndicesStarting(
                    at: currentFirstSlot,
                    fillDirection: newDirection
                )
            }
        }
        if pendingDraftPageIndex != nil {
            updatePendingDraftStatus(
                successMessage: "Fill order: \(newDirection.label)"
            )
        } else {
            captureQueueIssue = nil
            statusMessage = "Fill order: \(newDirection.label)"
        }
        schedulePreviewRefresh(immediate: true)
    }

    func enqueueCurrentLabel() {
        if document.printBatches.contains(where: { $0.capturedPlacement == nil }) {
            updateDocument(coalescingKey: nil) { document in
                document.freezeLegacyPrintQueuePlacement()
            }
        }
        let snapshot = prepareRenderableDocument()
        guard !snapshot.elements.isEmpty else {
            statusMessage = "Add at least one object before saving a label"
            return
        }
        let capturePageIndex: Int
        if snapshot.hasQueuedLabels {
            guard let pendingDraftPageIndex else {
                let message = "Choose an empty start position for the next capture."
                captureQueueIssue = message
                statusMessage = message
                return
            }
            capturePageIndex = pendingDraftPageIndex
        } else {
            capturePageIndex = pendingDraftPageIndex ?? currentPageIndex
        }

        let quantity = snapshot.currentSetupLabelCount
        let remainingCapacity = max(
            0,
            PrintBatch.quantityRange.upperBound - snapshot.queuedLabelCount
        )
        guard quantity <= remainingCapacity else {
            let message = "This capture would exceed the \(PrintBatch.quantityRange.upperBound.formatted())-label queue limit. Reduce End/Repeat Sets or reset the queue."
            captureQueueIssue = message
            statusMessage = message
            return
        }
        let editSession = printBatchEditSession
        var batchID = UUID()
        var startSlotOffset = 0
        if let editSession {
            if !snapshot.printBatches.contains(where: { $0.id == editSession.batchID }) {
                batchID = editSession.batchID
            }
            // Only reuse the frozen offset when the batch returns to its page;
            // a deliberately re-picked position starts at the area's beginning.
            if capturePageIndex == editSession.startPageIndex {
                startSlotOffset = editSession.startSlotOffset
            }
        }
        let batchNumber = snapshot.printBatches.count + 1
        let batch = PrintBatch(
            id: batchID,
            name: printBatchName(elements: snapshot.elements, fallbackNumber: batchNumber),
            quantity: quantity,
            elements: snapshot.elements,
            serialSettings: snapshot.serial,
            dataTable: snapshot.dataTable,
            capturedPlacement: snapshot.placement,
            startPageIndex: capturePageIndex,
            startSlotOffset: startSlotOffset
        )

        if let conflict = snapshot.firstPlacementConflict(for: batch) {
            let coordinate = snapshot.coordinateLabel(for: conflict.slotIndex)
            let message = "Page \(conflict.pageIndex + 1) \(coordinate) is already fixed by “\(conflict.existingBatchName)”. Choose an empty start position for the next capture."
            captureQueueIssue = message
            statusMessage = message
            return
        }

        updateDocument(coalescingKey: nil) { document in
            var batches = document.printQueue ?? []
            let insertIndex = editSession.map { min($0.queueIndex, batches.count) } ?? batches.count
            batches.insert(batch, at: insertIndex)
            document.printQueue = batches
        }
        printBatchEditSession = nil
        pendingDraftPageIndex = nil
        captureQueueIssue = nil
        clampCurrentPageIndex()
        schedulePreviewRefresh(immediate: true)
        statusMessage = editSession != nil
            ? "Updated \(batch.name) with \(quantity) label(s)."
            : "Captured \(batch.name) with \(quantity) label(s). Choose another empty position for the next capture."
    }

    /// Take a captured batch out of the queue and load its snapshot (label,
    /// numbering/CSV, placement) back into the editor. The next capture puts
    /// the updated setup back in the same queue position and sheet slots.
    func beginEditingPrintBatch(id: UUID) {
        if let session = printBatchEditSession {
            let message = "Finish editing \(session.batchName) first — Update Capture or Cancel."
            captureQueueIssue = message
            statusMessage = message
            return
        }
        printBatchMoveSession = nil
        var snapshot = document
        snapshot.freezeLegacyPrintQueuePlacement()
        guard let queueIndex = snapshot.printBatches.firstIndex(where: { $0.id == id }) else {
            statusMessage = "This capture is no longer in the queue."
            return
        }
        let batch = snapshot.printBatches[queueIndex]
        let session = PrintBatchEditSession(
            batchID: batch.id,
            batchName: batch.name,
            queueIndex: queueIndex,
            startPageIndex: batch.startPageIndex ?? 0,
            startSlotOffset: batch.startSlotOffset ?? 0,
            previousDocument: document,
            previousPendingDraftPageIndex: pendingDraftPageIndex,
            previousCurrentPageIndex: currentPageIndex
        )

        updateDocument(coalescingKey: nil) { document in
            document.freezeLegacyPrintQueuePlacement()
            var batches = document.printQueue ?? []
            batches.removeAll { $0.id == id }
            document.printQueue = batches.isEmpty ? nil : batches
            document.elements = batch.elements
            if let serial = batch.serialSettings {
                document.serial = serial
            }
            document.dataTable = batch.dataTable
            if let placement = batch.capturedPlacement {
                document.placement = placement
            }
        }
        printBatchEditSession = session
        pendingDraftPageIndex = session.startPageIndex
        currentPageIndex = session.startPageIndex
        selectedElementID = document.elements.first?.id
        editingElementID = nil
        captureQueueIssue = nil
        clampCurrentPageIndex()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Editing \(batch.name). Adjust the setup, then Update Capture."
    }

    /// Abandon the current capture edit and put the original batch back.
    func cancelPrintBatchEdit() {
        guard let session = printBatchEditSession else { return }
        recordUndo(coalescingKey: nil)
        document = session.previousDocument
        document.clampElementsToSheet()
        printBatchEditSession = nil
        pendingDraftPageIndex = session.previousPendingDraftPageIndex
        currentPageIndex = session.previousCurrentPageIndex
        selectedElementID = document.elements.first?.id
        editingElementID = nil
        captureQueueIssue = nil
        clampCurrentPageIndex()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Returned \(session.batchName) to the queue unchanged."
    }

    /// Arm reposition mode for a captured batch: the next click on the page
    /// preview moves the batch's fixed slots there. Clicking the same batch's
    /// button again cancels.
    func beginMovingPrintBatch(id: UUID) {
        if let session = printBatchEditSession {
            let message = "Finish editing \(session.batchName) first — Update Capture or Cancel."
            captureQueueIssue = message
            statusMessage = message
            return
        }
        if printBatchMoveSession?.batchID == id {
            cancelPrintBatchMove()
            return
        }
        ensureLegacyQueueIsFrozen()
        guard let batch = document.printBatches.first(where: { $0.id == id }) else {
            statusMessage = "This capture is no longer in the queue."
            return
        }
        printBatchMoveSession = PrintBatchMoveSession(batchID: batch.id, batchName: batch.name)
        captureQueueIssue = nil
        statusMessage = "Click an empty label position to move \(batch.name). Use Prev/Next to reach another page."
    }

    func cancelPrintBatchMove() {
        guard printBatchMoveSession != nil else { return }
        printBatchMoveSession = nil
        statusMessage = "Cancelled the capture move"
    }

    private func repositionPrintBatch(_ session: PrintBatchMoveSession, to slotIndex: Int) {
        guard let queueIndex = document.printBatches.firstIndex(where: { $0.id == session.batchID }) else {
            printBatchMoveSession = nil
            statusMessage = "This capture is no longer in the queue."
            return
        }
        var moved = document.printBatches[queueIndex]
        let fillDirection = moved.capturedPlacement?.fillDirection
            ?? document.placement.fillDirection
        moved.capturedPlacement = PlacementSettings(
            selectedSlotIndices: document.slotIndicesStarting(
                at: slotIndex,
                fillDirection: fillDirection
            ),
            fillDirection: fillDirection
        )
        moved.startPageIndex = currentPageIndex
        moved.startSlotOffset = 0

        // Conflict-check against the rest of the queue only: the batch's own
        // former slots are exactly what this move is allowed to leave.
        var others = document
        var remaining = others.printQueue ?? []
        remaining.removeAll { $0.id == session.batchID }
        others.printQueue = remaining.isEmpty ? nil : remaining
        if let conflict = others.firstPlacementConflict(for: moved) {
            let coordinate = document.coordinateLabel(for: conflict.slotIndex)
            let message = "Page \(conflict.pageIndex + 1) \(coordinate) is already fixed by “\(conflict.existingBatchName)”. Choose another empty position."
            captureQueueIssue = message
            statusMessage = message
            return
        }

        updateDocument(coalescingKey: nil) { document in
            var batches = document.printQueue ?? []
            if let index = batches.firstIndex(where: { $0.id == session.batchID }) {
                batches[index] = moved
            }
            document.printQueue = batches
        }
        printBatchMoveSession = nil
        captureQueueIssue = nil
        clampCurrentPageIndex()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Moved \(session.batchName) to page \(currentPageIndex + 1) \(document.coordinateLabel(for: slotIndex))"
    }

    func removePrintBatch(id: UUID) {
        updateDocument(coalescingKey: nil) { document in
            var batches = document.printQueue ?? []
            batches.removeAll { $0.id == id }
            document.printQueue = batches.isEmpty ? nil : batches
        }
        if printBatchMoveSession?.batchID == id {
            printBatchMoveSession = nil
        }
        if !document.hasQueuedLabels {
            pendingDraftPageIndex = currentPageIndex
        }
        captureQueueIssue = nil
        clampCurrentPageIndex()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Removed label from the print queue"
    }

    func movePrintBatch(id: UUID, by offset: Int) {
        guard offset != 0 else { return }
        updateDocument(coalescingKey: nil) { document in
            guard var batches = document.printQueue,
                  let source = batches.firstIndex(where: { $0.id == id })
            else { return }
            let destination = min(max(0, source + offset), batches.count - 1)
            guard destination != source else { return }
            let batch = batches.remove(at: source)
            batches.insert(batch, at: destination)
            document.printQueue = batches
        }
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Reordered print queue"
    }

    func clearPrintQueue() {
        guard !document.printBatches.isEmpty else { return }
        updateDocument(coalescingKey: nil) { document in
            document.printQueue = nil
        }
        currentPageIndex = 0
        pendingDraftPageIndex = 0
        captureQueueIssue = nil
        printBatchEditSession = nil
        printBatchMoveSession = nil
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Reset the capture queue"
    }

    private func printBatchName(elements: [LabelElement], fallbackNumber: Int) -> String {
        let firstLine = elements
            .filter { $0.type == .text }
            .lazy
            .flatMap { $0.content.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let firstLine else { return "Label \(fallbackNumber)" }
        let limit = 30
        if firstLine.count <= limit {
            return firstLine
        }
        return "\(firstLine.prefix(limit - 1))…"
    }

    func normalizeCircleTextFrames(in document: inout LabelDocument) {
        guard document.sheet.shape == .circle else { return }
        let safeFrame = document.sheet.textSafeFrame
        let fullFrame = RectMM(
            x: 0,
            y: 0,
            width: document.sheet.labelWidthMM,
            height: document.sheet.labelHeightMM
        )
        // The previous 680 editor created a centered 92%-size rectangle and
        // nudged it upward by 0.12 mm. Recognize that exact legacy default
        // (and the unbiased variant used by other circle formats) so opening
        // an older project upgrades both its canvas and captured snapshots.
        let legacyWidth = max(8, document.sheet.labelWidthMM * 0.92)
        let legacyHeight = max(8, document.sheet.labelHeightMM * 0.92)
        let legacyX = max(0, (document.sheet.labelWidthMM - legacyWidth) / 2)
        let legacyY = max(0, (document.sheet.labelHeightMM - legacyHeight) / 2)
        let legacyCenteredFrame = RectMM(
            x: legacyX,
            y: legacyY,
            width: legacyWidth,
            height: legacyHeight
        )
        let legacy680Frame = RectMM(
            x: legacyX,
            y: max(0, legacyY - 0.12),
            width: legacyWidth,
            height: legacyHeight
        )

        func approximatelyEqual(_ lhs: RectMM, _ rhs: RectMM) -> Bool {
            let tolerance = 0.02
            return abs(lhs.x - rhs.x) <= tolerance
                && abs(lhs.y - rhs.y) <= tolerance
                && abs(lhs.width - rhs.width) <= tolerance
                && abs(lhs.height - rhs.height) <= tolerance
        }

        func normalized(_ elements: [LabelElement]) -> [LabelElement] {
            elements.map { element in
                guard element.type == .text else { return element }
                var copy = element
                let isLegacyCircularFrame = element.usesCircularTextFlow == nil
                    && (
                        approximatelyEqual(element.frame, safeFrame)
                        || approximatelyEqual(element.frame, fullFrame)
                        || approximatelyEqual(element.frame, legacyCenteredFrame)
                        || (
                            document.formatCode == "680"
                            && approximatelyEqual(element.frame, legacy680Frame)
                        )
                    )
                if element.usesCircularTextFlow == true || isLegacyCircularFrame {
                    copy.usesCircularTextFlow = true
                    copy.frame = fullFrame
                } else {
                    copy.frame = element.frame.clamped(
                        maxWidth: document.sheet.labelWidthMM,
                        maxHeight: document.sheet.labelHeightMM
                    )
                }
                return copy
            }
        }

        document.elements = normalized(document.elements)
        if var batches = document.printQueue {
            for index in batches.indices {
                batches[index].elements = normalized(batches[index].elements)
            }
            document.printQueue = batches
        }
    }

    func newDocument() {
        document = .starter
        document.printAutomation = loadCachedPrintAutomation()
        applyStartupSheetSetup()
        currentPageIndex = 0
        pendingDraftPageIndex = 0
        projectURL = nil
        selectedElementID = document.elements.first?.id
        editingElementID = nil
        printBatchEditSession = nil
        printBatchMoveSession = nil
        clearUndoHistory()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Started a new label project"
    }

    func applyPreset(id: String) {
        guard !document.hasQueuedLabels else {
            statusMessage = "Reset the capture queue before changing label format"
            return
        }
        guard let preset = SheetTemplate.presets.first(where: { $0.id == id }) else {
            return
        }
        updateSheet { sheet in
            sheet = preset
        }
        document.formatCode = nil
        document.formatFamily = nil
        document.formatSourceURL = nil
        document.formatPDFTemplateURL = nil
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Applied preset: \(preset.name)"
    }

    func applyOfficialFormat(code: String) {
        guard let format = officialFormats.first(where: { $0.code == code }) else {
            return
        }
        applyOfficialFormat(format, updateTitle: false)
    }

    func applyOfficialFormat(_ format: OfficialFormatDefinition, updateTitle: Bool) {
        guard !document.hasQueuedLabels else {
            statusMessage = "Reset the capture queue before changing label format"
            return
        }
        let shouldResetToBlankCanvas = document.elements.isEmpty || document.elements == LabelDocument.starter.elements
        updateDocument { document in
            document.sheet = format.sheetTemplate
            document.formatCode = format.code
            document.formatFamily = format.family
            document.formatSourceURL = format.detailURL
            document.formatPDFTemplateURL = format.pdfTemplateURL
            normalizeCircleTextFrames(in: &document)
            if shouldResetToBlankCanvas {
                document.elements = []
            }
            if updateTitle || document.title == "iLabel2Mac Demo" || document.title.isEmpty {
                document.title = format.code
            }
        }
        if shouldResetToBlankCanvas {
            selectedElementID = nil
        }
        editingElementID = nil
        persistLastSheetSetup()
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Applied official format: \(format.code)"
    }

    func addElement(_ type: ElementType) {
        recordUndo(coalescingKey: nil)
        let count = document.elements.filter { $0.type == type }.count + 1
        let element: LabelElement
        switch type {
        case .text:
            element = makeCenteredTextElement(index: count)
        default:
            element = LabelElement.make(type, index: count)
        }
        document.elements.append(element)
        selectedElementID = element.id
        editingElementID = type == .text ? element.id : nil
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Added \(type.label)"
    }

    private func makeCenteredTextElement(index: Int) -> LabelElement {
        var element = LabelElement.make(.text, index: index)

        let elementWidth: Double
        let elementHeight: Double
        let centeredX: Double
        let centeredY: Double
        switch document.sheet.shape {
        case .circle:
            elementWidth = document.sheet.labelWidthMM
            elementHeight = document.sheet.labelHeightMM
            centeredX = 0
            centeredY = 0
            element.usesCircularTextFlow = true
        case .capsule:
            elementWidth = max(10, document.sheet.labelWidthMM * 0.90)
            elementHeight = max(8, document.sheet.labelHeightMM * 0.82)
            centeredX = max(0, (document.sheet.labelWidthMM - elementWidth) / 2)
            centeredY = max(0, (document.sheet.labelHeightMM - elementHeight) / 2)
        case .rectangle, .roundedRectangle:
            elementWidth = max(10, document.sheet.labelWidthMM * 0.90)
            elementHeight = max(8, document.sheet.labelHeightMM * 0.78)
            centeredX = max(0, (document.sheet.labelWidthMM - elementWidth) / 2)
            centeredY = max(0, (document.sheet.labelHeightMM - elementHeight) / 2)
        }

        element.frame = RectMM(
            x: centeredX,
            y: centeredY,
            width: elementWidth,
            height: elementHeight
        )
        element.content = document.serial.mode == .rangedSets ? "{{serial}}\n{{date}}" : "{{date}}"
        element.fontName = "Arial"
        element.fontSize = 3.5
        element.isBold = false
        element.isItalic = false
        element.isUnderline = false
        element.textAlignment = .center
        element.foreground = .black
        element.background = .clear
        element.stroke = .clear
        element.strokeWidth = 0
        element.cornerRadiusMM = 0

        return element
    }

    func fitSelectedTextToLabel() {
        guard let selectedElement, selectedElement.type == .text else { return }
        let sheet = document.sheet
        updateSelected { element in
            if sheet.shape == .circle {
                element.frame = RectMM(
                    x: 0,
                    y: 0,
                    width: sheet.labelWidthMM,
                    height: sheet.labelHeightMM
                )
                element.usesCircularTextFlow = true
            } else {
                let width = min(element.frame.width, sheet.labelWidthMM)
                let height = min(element.frame.height, sheet.labelHeightMM)
                element.frame = RectMM(
                    x: max(0, (sheet.labelWidthMM - width) / 2),
                    y: max(0, (sheet.labelHeightMM - height) / 2),
                    width: width,
                    height: height
                )
                element.usesCircularTextFlow = false
            }
            element.textAlignment = .center
        }
        statusMessage = sheet.shape == .circle
            ? "Fitted text to the full circular label"
            : "Centered text in the label"
    }

    func duplicateSelected() {
        guard var copy = selectedElement else { return }
        recordUndo(coalescingKey: nil)
        copy.id = UUID()
        copy.name += " Copy"
        copy.frame.x += 3
        copy.frame.y += 3
        copy.frame = copy.frame.clamped(maxWidth: document.sheet.labelWidthMM, maxHeight: document.sheet.labelHeightMM)
        if document.sheet.shape == .circle,
           copy.type == .text,
           copy.usesCircularTextFlow == true {
            copy.frame = RectMM(
                x: 0,
                y: 0,
                width: document.sheet.labelWidthMM,
                height: document.sheet.labelHeightMM
            )
        }
        document.elements.append(copy)
        selectedElementID = copy.id
        editingElementID = nil
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Duplicated \(copy.type.label.lowercased())"
    }

    func deleteSelected() {
        guard let selectedElementID, let index = document.elements.firstIndex(where: { $0.id == selectedElementID }) else {
            return
        }

        recordUndo(coalescingKey: nil)
        let removed = document.elements.remove(at: index)
        self.selectedElementID = document.elements.last?.id
        if editingElementID == removed.id {
            editingElementID = nil
        }
        schedulePreviewRefresh(immediate: true)
        statusMessage = "Deleted \(removed.name)"
    }

    func movePage(delta: Int) {
        currentPageIndex = min(
            max(0, currentPageIndex + delta),
            max(0, navigationPageCount - 1)
        )
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            var loaded = try JSONDecoder().decode(LabelDocument.self, from: data)
            loaded.freezeLegacyPrintQueuePlacement()
            // Register bundled custom fonts (process scope) so missing fonts
            // resolve to the original faces, then drop the bytes from memory.
            FontEmbedder.register(loaded.embeddedFonts)
            loaded.embeddedFonts = nil
            document = loaded
            document.clampElementsToSheet()
            normalizeCircleTextFrames(in: &document)
            // Wi-Fi print setup follows the machine, not the file — opening
            // an old project must not flip off "Switch Wi-Fi on Print" or
            // revert the printer credentials configured on this Mac.
            document.printAutomation = PrintAutomationSettings.resolvedOnOpen(
                machineCached: loadCachedPrintAutomation(),
                documentValue: document.printAutomation
            )
            persistPrintAutomationCache(document.printAutomation)
            // The opened project's stock is now the "last used" size that a
            // future New/launch starts from.
            persistLastSheetSetup()
            projectURL = url
            selectedElementID = document.elements.first?.id
            editingElementID = nil
            printBatchEditSession = nil
            printBatchMoveSession = nil
            currentPageIndex = 0
            pendingDraftPageIndex = document.hasQueuedLabels ? nil : 0
            clearUndoHistory()
            schedulePreviewRefresh(immediate: true)
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            statusMessage = "Open failed: \(error.localizedDescription)"
        }
    }

    func saveProject() {
        do {
            // Bundle any custom (non-system) fonts into the saved copy so the
            // project renders identically on machines that lack them. Kept out
            // of the live in-memory document to keep undo snapshots light.
            var documentToSave = document
            documentToSave.embeddedFonts = FontEmbedder.collect(from: documentToSave)
            let data = try JSONEncoder.pretty.encode(documentToSave)
            let targetURL = try saveURL(
                existingURL: projectURL,
                suggestedName: "\(document.title.replacingOccurrences(of: " ", with: "-")).ilabel.json",
                allowedTypes: [.json]
            )
            try data.write(to: targetURL, options: .atomic)
            projectURL = targetURL
            statusMessage = "Saved \(targetURL.lastPathComponent)"
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let table = try CSVParser.parse(url: url)
            document.dataTable = table
            currentPageIndex = 0
            schedulePreviewRefresh(immediate: true)
            statusMessage = "Loaded \(table.rows.count) data rows from \(url.lastPathComponent)"
        } catch {
            statusMessage = "CSV import failed: \(error.localizedDescription)"
        }
    }

    func pickImageForSelected() {
        guard let selected = selectedElement, selected.type == .image else {
            statusMessage = "Select an image element first"
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            updateSelected { element in
                element.imageData = data
                if element.name == selected.name {
                    element.name = url.deletingPathExtension().lastPathComponent
                }
            }
            statusMessage = "Placed image: \(url.lastPathComponent)"
        } catch {
            statusMessage = "Image import failed: \(error.localizedDescription)"
        }
    }

    func exportPDF() {
        do {
            let renderDocument = prepareRenderableDocument()
            let data = PageRenderer.pdfData(document: renderDocument, pageIndex: currentPageIndex)
            let url = try saveURL(
                existingURL: nil,
                suggestedName: "\(renderDocument.title.replacingOccurrences(of: " ", with: "-"))-page-\(currentPageIndex + 1).pdf",
                allowedTypes: [.pdf]
            )
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported PDF: \(url.lastPathComponent)"
        } catch {
            statusMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    func exportAllPagesPDF() {
        do {
            let renderDocument = prepareRenderableDocument()
            let pageCount = renderDocument.pageCount
            let data = PageRenderer.pdfDataAllPages(document: renderDocument)
            let url = try saveURL(
                existingURL: nil,
                suggestedName: "\(renderDocument.title.replacingOccurrences(of: " ", with: "-"))-all-\(pageCount)pages.pdf",
                allowedTypes: [.pdf]
            )
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported PDF (\(pageCount) page\(pageCount == 1 ? "" : "s")): \(url.lastPathComponent)"
        } catch {
            statusMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    func exportPNG() {
        do {
            let renderDocument = prepareRenderableDocument()
            guard let data = PageRenderer.pngData(document: renderDocument, pageIndex: currentPageIndex) else {
                statusMessage = "PNG export failed"
                return
            }
            let url = try saveURL(
                existingURL: nil,
                suggestedName: "\(renderDocument.title.replacingOccurrences(of: " ", with: "-"))-page-\(currentPageIndex + 1).png",
                allowedTypes: [.png]
            )
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported PNG: \(url.lastPathComponent)"
        } catch {
            statusMessage = "PNG export failed: \(error.localizedDescription)"
        }
    }

    func printCurrentPage() {
        submitPrint(allPages: false)
    }

    func printAllPages() {
        submitPrint(allPages: true)
    }

    private func submitPrint(allPages: Bool) {
        let snapshot = prepareRenderableDocument()
        let pageIndex = currentPageIndex
        let settings = document.printAutomation
        let outputDescription = allPages
            ? "\(snapshot.pageCount) page\(snapshot.pageCount == 1 ? "" : "s")"
            : "page \(pageIndex + 1)"

        // The dialog runs on the user's normal network; the printer's Wi-Fi
        // is only needed for the transmission itself. So: submit first, then
        // check whether the job drains where we are (printer on the same
        // LAN), and only switch — for as short a window as possible — when
        // it doesn't. A failed switch leaves the job queued in CUPS; it
        // prints whenever the printer becomes reachable.
        //
        // Chained on the previous run: two rapid prints must not interleave
        // (one restoring the network while the other is still transmitting).
        let previousRun = wifiAutomationTask
        wifiAutomationTask = Task {
            await previousRun?.value

            // Jobs already in the queue are not ours; only what appears
            // after this dialog counts as this print's delivery.
            let baselineJobs = WiFiPrintAutomation.pendingJobIDs() ?? []

            let didSubmit = await MainActor.run {
                if allPages {
                    PageRenderer.printAllPages(document: snapshot)
                } else {
                    PageRenderer.print(document: snapshot, pageIndex: pageIndex)
                }
            }

            guard didSubmit else {
                await MainActor.run {
                    statusMessage = "Print cancelled"
                    wifiTestStatus = settings.enabled ? "Print cancelled — Wi-Fi untouched" : "Wi-Fi print disabled"
                }
                return
            }

            guard settings.enabled else {
                await MainActor.run {
                    refreshCurrentWiFiSSID()
                    wifiTestStatus = "Printed without Wi-Fi switching"
                    statusMessage = "Sent \(outputDescription) to one print dialog"
                }
                return
            }

            await MainActor.run {
                wifiTestStatus = "Sending job..."
                statusMessage = "Checking if the printer is reachable without switching..."
            }
            if await WiFiPrintAutomation.newJobsCleared(baseline: baselineJobs, timeoutSeconds: 4.0) {
                await MainActor.run {
                    refreshCurrentWiFiSSID()
                    wifiTestStatus = "Printed without switching (printer reachable directly)"
                    statusMessage = "Printed \(outputDescription) — no Wi-Fi switch needed"
                }
                return
            }

            await MainActor.run {
                wifiTestStatus = "Connecting to \(settings.printerSSID)..."
                statusMessage = "Connecting to printer Wi-Fi to deliver the job..."
            }
            let session: WiFiPrintSession?
            do {
                // Keep scanning while the printer's SoftAP wakes up: the job
                // is already queued, so the moment the network appears the
                // join fires and delivery happens automatically.
                session = try await WiFiPrintAutomation.prepare(
                    settings: settings,
                    discoveryTimeoutSeconds: 90
                ) { message in
                    Task { @MainActor [weak self] in
                        self?.wifiTestStatus = message
                        self?.statusMessage = message
                    }
                }
            } catch {
                await MainActor.run {
                    refreshCurrentWiFiSSID()
                    wifiTestStatus = "Wi-Fi switch failed: \(error.localizedDescription)"
                    statusMessage = "Job stays queued — it prints when the printer is reachable"
                }
                return
            }

            if session != nil {
                let nanoseconds = UInt64(max(0, settings.settleSeconds) * 1_000_000_000)
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
                // A queue that stopped while the printer was unreachable
                // (default error policy is stop-printer) won't resume just
                // because the network is right now — kick it back on.
                WiFiPrintAutomation.resumeStoppedPrinters()
            }

            await MainActor.run {
                wifiTestStatus = "Sending job to printer..."
                statusMessage = "Waiting for the print job to reach the printer..."
            }
            // Critical: restoring the network mid-transfer aborts the job,
            // so wait for this print's own jobs to leave the queue first.
            let delivered = await WiFiPrintAutomation.newJobsCleared(
                baseline: baselineJobs,
                timeoutSeconds: 45.0
            )

            if let session {
                await MainActor.run {
                    wifiTestStatus = "Restoring previous Wi-Fi..."
                    statusMessage = "Restoring previous Wi-Fi..."
                }
                do {
                    try await session.restore()
                    await MainActor.run {
                        refreshCurrentWiFiSSID()
                        wifiTestStatus = "Restored to \(currentWiFiSSID)"
                        statusMessage = delivered
                            ? "Printed, then returned to previous Wi-Fi"
                            : "Returned to previous Wi-Fi — the job hadn't finished sending; check the printer"
                    }
                } catch {
                    await MainActor.run {
                        refreshCurrentWiFiSSID()
                        wifiTestStatus = "Restore failed: \(error.localizedDescription)"
                        statusMessage = "Printed, but couldn't rejoin the previous Wi-Fi — pick it from the Wi-Fi menu"
                    }
                }
            }
        }
    }

    private func prepareRenderableDocument() -> LabelDocument {
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        finishInlineEditing()
        schedulePreviewRefresh(immediate: true)
        return document
    }

    private func schedulePreviewRefresh(immediate: Bool = false) {
        if immediate {
            previewRefreshWorkItem?.cancel()
            previewRefreshWorkItem = nil
            lastPreviewRefreshAt = Date()
            previewDocument = document
            return
        }

        // While the inline editor is open the user watches the live NSTextView,
        // so the sheet preview may lag: never render it synchronously inside
        // the keystroke path (that's what made typing feel slow), and never
        // cancel-and-reschedule (a pure trailing debounce starves the preview
        // during continuous typing). One pending refresh per window publishes
        // the latest document when it fires; finishing the edit refreshes
        // immediately via the `immediate` path above.
        if editingElementID != nil {
            guard previewRefreshWorkItem == nil else { return }
            scheduleTrailingPreviewRefresh(after: 0.6)
            return
        }

        previewRefreshWorkItem?.cancel()
        previewRefreshWorkItem = nil

        // Leading edge outside editing: refresh right away unless one just
        // happened, so single edits (drags, inspector tweaks) feel live.
        if Date().timeIntervalSince(lastPreviewRefreshAt) >= previewRefreshInterval {
            lastPreviewRefreshAt = Date()
            previewDocument = document
            return
        }

        scheduleTrailingPreviewRefresh(after: previewRefreshInterval)
    }

    private func scheduleTrailingPreviewRefresh(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.previewRefreshWorkItem = nil
                self.lastPreviewRefreshAt = Date()
                self.previewDocument = self.document
            }
        }
        previewRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Start the given (fresh) document on the last label stock the user
    /// worked with; fall back to the factory default on first launch.
    private func applyStartupSheetSetup() {
        if let last = loadLastSheetSetup() {
            if let code = last.formatCode,
               let format = officialFormats.first(where: { $0.code == code }) {
                document.sheet = format.sheetTemplate
                document.formatCode = format.code
                document.formatFamily = format.family
                document.formatSourceURL = format.detailURL
                document.formatPDFTemplateURL = format.pdfTemplateURL
                document.title = format.code
                document.elements = []
                return
            }
            document.sheet = last.sheet
            document.formatCode = nil
            document.formatFamily = nil
            document.formatSourceURL = nil
            document.formatPDFTemplateURL = nil
            if !last.sheet.name.isEmpty {
                document.title = last.sheet.name
            }
            document.elements = []
            return
        }
        if let defaultFormat = officialFormats.first(where: { $0.code == defaultOfficialFormatCode }) {
            document.sheet = defaultFormat.sheetTemplate
            document.formatCode = defaultFormat.code
            document.formatFamily = defaultFormat.family
            document.formatSourceURL = defaultFormat.detailURL
            document.formatPDFTemplateURL = defaultFormat.pdfTemplateURL
            document.title = defaultFormat.code
            document.elements = []
        }
    }

    private func loadLastSheetSetup() -> LastSheetSetup? {
        guard let data = preferences.data(forKey: cachedLastSheetSetupKey) else {
            return nil
        }
        return try? JSONDecoder().decode(LastSheetSetup.self, from: data)
    }

    private func persistLastSheetSetup() {
        let setup = LastSheetSetup(formatCode: document.formatCode, sheet: document.sheet)
        guard let data = try? JSONEncoder().encode(setup) else { return }
        preferences.set(data, forKey: cachedLastSheetSetupKey)
    }

    private func loadCachedPrintAutomation() -> PrintAutomationSettings {
        if let data = preferences.data(forKey: cachedPrintAutomationKey),
           let settings = try? JSONDecoder().decode(PrintAutomationSettings.self, from: data) {
            return settings
        }
        // First launch on this machine: pre-fill from the Wi-Fi networks the
        // Mac already knows and persist immediately, so the seed (and its
        // process-spawning auto-detection) runs exactly once.
        let seeded = PrintAutomationSettings.seededDefault(
            detectedPrinterSSID: WiFiPrintAutomation.autoDetectedPrinterSSID()
        )
        persistPrintAutomationCache(seeded)
        return seeded
    }

    private func persistPrintAutomationCache(_ settings: PrintAutomationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        preferences.set(data, forKey: cachedPrintAutomationKey)
    }

    private func loadCachedQuickTextPresets() -> [String] {
        if let items = preferences.stringArray(forKey: cachedQuickTextPresetsKey), !items.isEmpty {
            return items
        }
        return ["DH5a", "TOP10", "JM110", "BL21(DE3)", "Stbl3"]
    }

    private func persistQuickTextPresets() {
        preferences.set(quickTextPresets, forKey: cachedQuickTextPresetsKey)
    }

    private func loadAppearanceMode() -> AppAppearanceMode {
        guard let raw = preferences.string(forKey: cachedAppearanceModeKey),
              let mode = AppAppearanceMode(rawValue: raw) else {
            return .system
        }
        return mode
    }

    private func persistAppearanceMode() {
        preferences.set(appearanceMode.rawValue, forKey: cachedAppearanceModeKey)
    }

    private func refreshCurrentWiFiSSID() {
        // macOS 15+ redacts the SSID from every CLI without Location Services,
        // so "Unknown" here is expected on modern systems, not an error.
        // Probing spawns networksetup on the main thread (~100-300ms stall),
        // and printCurrentPage refreshes this label several times per print —
        // on a redacted system it can never return anything, so skip it.
        if WiFiPrintAutomation.systemRedactsSSID {
            currentWiFiSSID = "Unknown (hidden by macOS)"
            return
        }
        currentWiFiSSID = WiFiPrintAutomation.currentSSID(service: document.printAutomation.wifiService) ?? "Unknown (hidden by macOS)"
    }

    private func saveURL(existingURL: URL?, suggestedName: String, allowedTypes: [UTType]) throws -> URL {
        if let existingURL {
            return existingURL
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedTypes

        guard panel.runModal() == .OK, let url = panel.url else {
            throw CocoaError(.userCancelled)
        }

        return url
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
