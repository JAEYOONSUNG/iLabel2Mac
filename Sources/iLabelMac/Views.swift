import SwiftUI
import AppKit

enum UIFormatters {
    static let decimal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

func scaled(_ value: Double, by scale: CGFloat) -> CGFloat {
    CGFloat(value) * scale
}

func pointsToDisplay(_ points: Double, unitScale: CGFloat) -> CGFloat {
    CGFloat(points) / CGFloat(mmToPointsRatio) * unitScale
}

func displayFont(name: String, size: CGFloat, isBold: Bool, isItalic: Bool = false) -> Font {
    let font = resolvedNSFont(name: name, size: size, isBold: isBold, isItalic: isItalic)
    return .custom(font.fontName, size: size)
}

func resolvedNSFont(name: String, size: CGFloat, isBold: Bool, isItalic: Bool = false) -> NSFont {
    let lowered = name.lowercased()
    if lowered == "arial" {
        let postScriptName: String
        switch (isBold, isItalic) {
        case (true, true):
            postScriptName = "Arial-BoldItalicMT"
        case (true, false):
            postScriptName = "Arial-BoldMT"
        case (false, true):
            postScriptName = "Arial-ItalicMT"
        case (false, false):
            postScriptName = "ArialMT"
        }
        return NSFont(name: postScriptName, size: size) ?? .systemFont(ofSize: size, weight: isBold ? .bold : .regular)
    }
    if let exact = NSFont(name: name, size: size) {
        return exact
    }
    let traits: NSFontTraitMask = [
        isBold ? .boldFontMask : [],
        isItalic ? .italicFontMask : []
    ].reduce([]) { $0.union($1) }
    if let family = NSFontManager.shared.font(withFamily: name, traits: traits, weight: isBold ? 9 : 5, size: size) {
        return family
    }
    return .systemFont(ofSize: size, weight: isBold ? .bold : .regular)
}

/// Font family enumeration hits the font subsystem and the inspector body
/// runs on every keystroke, so both lists are computed once. Installed fonts
/// changing mid-session is rare enough to ignore.
let installedFontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()
private let installedFontFamilyLookup: Set<String> = Set(installedFontFamilies.map { $0.lowercased() })

/// True when `name` resolves to a real installed font (family or PostScript
/// name) rather than silently falling back to the system font. Used to warn
/// when a project made on another Mac references a font not installed here,
/// which shifts text size/position.
func fontFamilyIsAvailable(_ name: String) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    if installedFontFamilyLookup.contains(trimmed.lowercased()) {
        return true
    }
    return NSFont(name: trimmed, size: 12) != nil
}

func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? dark : light
    })
}

func appChromeBackground() -> Color {
    adaptiveColor(
        light: NSColor(calibratedWhite: 0.975, alpha: 1),
        dark: NSColor.windowBackgroundColor
    )
}

func appPanelBackground() -> Color {
    adaptiveColor(
        light: NSColor(calibratedRed: 0.985, green: 0.987, blue: 0.992, alpha: 1),
        dark: NSColor.underPageBackgroundColor
    )
}

func appCardBackground() -> Color {
    adaptiveColor(
        light: NSColor.white,
        dark: NSColor.textBackgroundColor
    )
}

func editorGradientTop() -> Color {
    adaptiveColor(
        light: NSColor(calibratedRed: 0.992, green: 0.994, blue: 1.0, alpha: 1),
        dark: NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.22, alpha: 1)
    )
}

func editorGradientBottom() -> Color {
    adaptiveColor(
        light: NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.988, alpha: 1),
        dark: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)
    )
}

struct ContentView: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        VStack(spacing: 0) {
            ToolbarStrip(store: store)
            Divider()

            // Pane minimums must sum to less than the window's minimum width
            // (plus dividers) or shrinking the window clips the inspector on
            // the right instead of compressing the panes.
            HSplitView {
                SidebarView(store: store)
                    .frame(minWidth: 230, idealWidth: 270, maxWidth: 300)

                EditorPane(store: store)
                    .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                InspectorView(store: store)
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 340)
            }
        }
        .background(appChromeBackground())
        .overlay(alignment: .bottomTrailing) {
            UpdateBannerView()
        }
    }
}

struct ToolbarStrip: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        // Horizontally scrollable so a narrow window scrolls the toolbar
        // instead of clipping the trailing controls.
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
            ControlGroup {
                Button("New", action: store.newDocument)
                Button("Open", action: store.openProject)
                Button("Save", action: store.saveProject)
            }

            ToolbarSeparator()

            ControlGroup {
                Button {
                    store.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!store.canUndo)
                .help("Undo (⌘Z)")

                Button {
                    store.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!store.canRedo)
                .help("Redo (⇧⌘Z)")
            }

            ToolbarSeparator()

            ControlGroup {
                Button("CSV", action: store.importCSV)

                Menu("Export") {
                    Button("Current Page as PDF", action: store.exportPDF)
                    Button("All Pages as PDF", action: store.exportAllPagesPDF)
                        .disabled(store.document.pageCount <= 1)
                    Divider()
                    Button("Current Page as PNG", action: store.exportPNG)
                }
                .help("Export PDF or PNG")

                Button(store.document.hasQueuedLabels ? "Print Captures" : "Print") {
                    if store.document.hasQueuedLabels {
                        store.printAllPages()
                    } else {
                        store.printCurrentPage()
                    }
                }
                .help(store.document.hasQueuedLabels
                    ? "Print every captured setup in one print job"
                    : "Print the current page")
            }

            ToolbarSeparator()

            Menu("Add Object") {
                Button("Text") { store.addElement(.text) }
                Button("Shape") { store.addElement(.rectangle) }
                Button("Image") {
                    store.addElement(.image)
                    store.pickImageForSelected()
                }
                Button("QR") { store.addElement(.qrCode) }
                Button("Barcode") { store.addElement(.code128) }
            }
            .help("Add text, shape, image, QR, or barcode")

            ToolbarSeparator()

            Picker("Canvas", selection: $store.canvasMode) {
                ForEach(CanvasMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            ToolbarSeparator()

            Picker("Theme", selection: $store.appearanceMode) {
                ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 82)
            .help("Appearance")

            ToolbarSeparator()

            ControlGroup {
                Button {
                    store.movePage(delta: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                    .disabled(store.currentPageIndex == 0)
                    .help("Previous page")

                Text(
                    store.isCaptureStagingPage
                        ? "New Page \(store.currentPageIndex + 1)"
                        : "Page \(store.currentPageIndex + 1) / \(store.document.pageCount)"
                )
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 104)

                Button {
                    store.movePage(delta: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                    .disabled(store.currentPageIndex >= store.navigationPageCount - 1)
                    .help("Next page")
            }

            Spacer(minLength: 20)

            Text(store.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        }
        .background {
            // Invisible shortcut carriers. Disabled while inline-editing text so
            // the NSTextView keeps its own ⌘Z for character-level undo.
            Group {
                Button("Undo", action: store.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo || store.editingElementID != nil)
                Button("Redo", action: store.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo || store.editingElementID != nil)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .frame(height: 46)
        .background(
            LinearGradient(
                colors: [
                    appPanelBackground(),
                    appChromeBackground()
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityIdentifier("toolbar")
    }
}

struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 18)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case sheet
    case data
    case layers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sheet: "Sheet"
        case .data: "Merge Data"
        case .layers: "Layers"
        }
    }
}

struct SidebarView: View {
    @ObservedObject var store: DocumentStore
    @AppStorage("sidebar.section") private var selectedSectionRaw = SidebarSection.sheet.rawValue
    @State private var formatChooserPresented = false

    private var selectedSection: SidebarSection {
        SidebarSection(rawValue: selectedSectionRaw) ?? .sheet
    }

    var body: some View {
        VStack(spacing: 0) {
            projectHeader
                .padding(12)

            Picker("Setup section", selection: $selectedSectionRaw) {
                ForEach(SidebarSection.allCases) { section in
                    Text(section.label).tag(section.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            switch selectedSection {
            case .sheet:
                sheetPage
            case .data:
                dataPage
            case .layers:
                layersPage
            }
        }
        .background(appPanelBackground())
        .sheet(isPresented: $formatChooserPresented) {
            OfficialFormatChooser(store: store)
                .frame(minWidth: 620, minHeight: 620)
        }
        .accessibilityIdentifier("setupSidebar")
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Project")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.document.hasQueuedLabels {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Format and sheet geometry are locked by the capture queue")
                }
            }

            TextField("Project title", text: documentBinding(\.title))
                .controlSize(.small)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.document.formatCode ?? "Custom")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(store.currentFormat?.sizeSummary ?? currentSheetSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(store.currentFormat?.family.label ?? "Custom")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )

            HStack(spacing: 6) {
                Button("Choose Format…") {
                    formatChooserPresented = true
                }
                .disabled(store.document.hasQueuedLabels)

                Menu("Presets") {
                    ForEach(SheetTemplate.presets) { preset in
                        Button(preset.name) {
                            store.applyPreset(id: preset.id)
                        }
                    }
                }
                .disabled(store.document.hasQueuedLabels)
                .help("Sheet Presets")
            }
            .controlSize(.small)
        }
    }

    private var sheetPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Sheet Layout") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dimensions in mm")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        DimensionGrid(
                            title: "Page",
                            width: sheetBinding(\.pageWidthMM),
                            height: sheetBinding(\.pageHeightMM)
                        )

                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 6
                        ) {
                            CompactStepperField(title: "Columns", value: sheetBinding(\.columns), range: 1...12)
                            CompactStepperField(title: "Rows", value: sheetBinding(\.rows), range: 1...20)
                        }

                        DimensionGrid(
                            title: "Label",
                            width: sheetBinding(\.labelWidthMM),
                            height: sheetBinding(\.labelHeightMM)
                        )
                        DimensionGrid(
                            title: "Gap",
                            width: sheetBinding(\.horizontalGapMM),
                            height: sheetBinding(\.verticalGapMM)
                        )
                        DimensionGrid(
                            title: "Margins",
                            width: sheetBinding(\.marginLeftMM),
                            height: sheetBinding(\.marginTopMM)
                        )

                        HStack(alignment: .bottom, spacing: 8) {
                            CompactDecimalField(
                                title: "Corner",
                                unit: "mm",
                                value: sheetBinding(\.cornerRadiusMM),
                                step: 0.25,
                                range: 0...100
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Shape")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Picker("Shape", selection: sheetBinding(\.shape)) {
                                    ForEach(LabelShape.allCases) { shape in
                                        Text(shape.label).tag(shape)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .disabled(store.document.hasQueuedLabels)

                if store.document.hasQueuedLabels {
                    Label(
                        "Open Queue from the Capture bar, then reset it to change the format or sheet layout.",
                        systemImage: "lock.fill"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
    }

    private var dataPage: some View {
        ScrollView {
            GroupBox("Merge Data") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(
                            "\(store.document.dataTable?.rows.count ?? 0) rows",
                            systemImage: "tablecells"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        Spacer()
                        Button("Import CSV…", action: store.importCSV)
                            .controlSize(.small)
                    }

                    Text("Built-in: {{serial}}, {{page}}, {{slot}}, {{row}}, {{date}}")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let headers = store.document.dataTable?.headers, !headers.isEmpty {
                        Text("CSV columns")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        FlowTokenStack(tokens: headers.map { "{{\($0)}}" }) { token in
                            store.insertQuickTextPreset(token)
                        }
                    } else {
                        Text("Import a CSV file to create one label per row and insert column tokens into text.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
        }
    }

    private var layersPage: some View {
        ScrollView {
            GroupBox("Layers") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Menu("Add") {
                            Button("Text") { store.addElement(.text) }
                            Button("Shape") { store.addElement(.rectangle) }
                            Button("Image") {
                                store.addElement(.image)
                                store.pickImageForSelected()
                            }
                            Button("QR") { store.addElement(.qrCode) }
                            Button("Barcode") { store.addElement(.code128) }
                        }

                        Button("Duplicate", action: store.duplicateSelected)
                            .disabled(store.selectedElement == nil)
                        Button {
                            store.deleteSelected()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(store.selectedElement == nil)
                        .help("Delete selected layer")
                    }
                    .controlSize(.small)

                    if store.document.elements.isEmpty {
                        Text("Add text, a shape, an image, QR, or barcode.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    }

                    ForEach(store.document.elements) { element in
                        Button {
                            store.selectElement(element.id, beginEditing: element.type == .text)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: iconName(for: element.type))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14)
                                Text(element.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(element.type.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(store.selectedElementID == element.id ? Color.accentColor.opacity(0.14) : appCardBackground())
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
        }
    }

    private var currentSheetSummary: String {
        let sheet = store.document.sheet
        return String(
            format: "%d×%d · %g × %g mm",
            sheet.columns,
            sheet.rows,
            sheet.labelWidthMM,
            sheet.labelHeightMM
        )
    }

    private func iconName(for type: ElementType) -> String {
        switch type {
        case .text: "textformat"
        case .rectangle: "square"
        case .image: "photo"
        case .qrCode: "qrcode"
        case .code128: "barcode"
        }
    }

    private func documentBinding<Value>(_ keyPath: WritableKeyPath<LabelDocument, Value>) -> Binding<Value> {
        Binding(
            get: { store.document[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func sheetBinding<Value>(_ keyPath: WritableKeyPath<SheetTemplate, Value>) -> Binding<Value> {
        Binding(
            get: { store.document.sheet[keyPath: keyPath] },
            set: { newValue in
                store.updateSheet { sheet in
                    sheet[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

struct CompactNumberingSection: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        GroupBox("Numbering") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mode")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker("Mode", selection: serialModeBinding) {
                            ForEach(SerialMode.allCases) { mode in
                                Text(mode == .rangedSets ? "Range" : mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .help("Numbering Mode")
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fill Order")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Picker(
                            "Fill Order",
                            selection: fillDirectionBinding
                        ) {
                            ForEach(PlacementFillDirection.allCases) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 64), spacing: 6)
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    CompactStepperField(
                        title: "Start",
                        value: serialIntBinding(\.start),
                        range: 0...999_999
                    )
                    CompactStepperField(
                        title: "Step",
                        value: serialIntBinding(\.step),
                        range: 1...999
                    )
                    if store.document.serial.mode == .rangedSets {
                        CompactStepperField(
                            title: "End",
                            value: serialIntBinding(\.end),
                            range: 0...999_999
                        )
                        CompactStepperField(
                            title: "Repeat",
                            value: serialIntBinding(\.repeatSets),
                            range: 1...999
                        )
                    }
                }

                // These three short values stay on one row, including at the
                // preview column's 220pt minimum width.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 52), spacing: 6),
                        GridItem(.flexible(minimum: 52), spacing: 6),
                        GridItem(.flexible(minimum: 52), spacing: 0)
                    ],
                    alignment: .leading,
                    spacing: 6
                ) {
                    CompactStepperField(
                        title: "Digits",
                        value: serialIntBinding(\.digits),
                        range: 1...12
                    )
                    CompactTextField(
                        title: "Prefix",
                        text: serialStringBinding(\.prefix)
                    )
                    CompactTextField(
                        title: "Suffix",
                        text: serialStringBinding(\.suffix)
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "number")
                    if store.document.serial.mode == .rangedSets {
                        Text(
                            "\(store.document.serial.countPerSet) per set × \(max(1, store.document.serial.repeatSets)) = \(store.document.serial.totalGeneratedCount) labels"
                        )
                    } else {
                        Text(
                            "Continuous · \(store.document.currentSetupLabelCount) labels in selected area"
                        )
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .help("Use {{serial}}, {{serial_raw}}, {{set}}, and {{index_in_set}} in label text.")
        .accessibilityIdentifier("numberingSection")
    }

    private var serialModeBinding: Binding<SerialMode> {
        Binding(
            get: { store.document.serial.mode },
            set: { newValue in
                store.updateDocument { document in
                    document.serial.mode = newValue
                }
            }
        )
    }

    private var fillDirectionBinding: Binding<PlacementFillDirection> {
        Binding(
            get: { store.document.placement.fillDirection },
            set: { store.updatePlacementFillDirection($0) }
        )
    }

    private func serialIntBinding(
        _ keyPath: WritableKeyPath<SerialSettings, Int>
    ) -> Binding<Int> {
        Binding(
            get: { store.document.serial[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.serial[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func serialStringBinding(
        _ keyPath: WritableKeyPath<SerialSettings, String>
    ) -> Binding<String> {
        Binding(
            get: { store.document.serial[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.serial[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

/// Geometry belongs beside the print preview it changes, rather than in the
/// already-dense appearance inspector. At the normal preview width the four
/// frame edges occupy one row and the two global transforms occupy the next;
/// adaptive columns preserve the same controls at the minimum window width.
struct CompactFrameSection: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        if let selected = store.selectedElement {
            GroupBox("Frame") {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 58), spacing: 4)
                        ],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        CompactDecimalField(
                            title: "X",
                            unit: "mm",
                            value: selectedBinding(\.frame.x, defaultValue: 0),
                            step: 0.1
                        )
                        CompactDecimalField(
                            title: "Y",
                            unit: "mm",
                            value: selectedBinding(\.frame.y, defaultValue: 0),
                            step: 0.1
                        )
                        CompactDecimalField(
                            title: "W",
                            unit: "mm",
                            value: selectedBinding(\.frame.width, defaultValue: 10),
                            step: 0.1
                        )
                        CompactDecimalField(
                            title: "H",
                            unit: "mm",
                            value: selectedBinding(\.frame.height, defaultValue: 10),
                            step: 0.1
                        )
                    }

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 76), spacing: 6, alignment: .bottom)
                        ],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        CompactDecimalField(
                            title: "Rotation",
                            unit: "deg",
                            value: selectedBinding(\.rotation, defaultValue: 0),
                            step: 1
                        )
                        CompactDecimalField(
                            title: "Opacity",
                            value: selectedBinding(\.opacity, defaultValue: 1),
                            step: 0.05,
                            range: 0...1
                        )

                        if selected.type == .text {
                            Button {
                                store.fitSelectedTextToLabel()
                            } label: {
                                Label(
                                    store.document.sheet.shape == .circle ? "Fit" : "Center",
                                    systemImage: "scope"
                                )
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("Center the text box and keep it inside the label boundary")
                        }
                    }
                }
            }
            .accessibilityIdentifier("frameSection")
        }
    }

    private func selectedBinding<Value>(
        _ keyPath: WritableKeyPath<LabelElement, Value>,
        defaultValue: Value
    ) -> Binding<Value> {
        Binding(
            get: { store.selectedElement?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                store.updateSelected { element in
                    element[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

struct TextFormattingToolbar: View {
    @ObservedObject var store: DocumentStore
    @State private var emojiPresented = false
    @State private var highlightColor = Color(
        nsColor: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.20, alpha: 0.45)
    )

    var body: some View {
        if let selected = store.selectedElement, selected.type == .text {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CommitNumberField(
                        title: "Size",
                        value: selected.fontSize,
                        onCommit: { store.applyTextStyleAction(.fontSize($0)) }
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .help("Font Size (pt)")

                    FontFamilyPicker(
                        fontName: selected.fontName,
                        width: 88,
                        onSelect: { store.applyTextStyleAction(.fontFamily($0)) }
                    )
                    .equatable()

                    ControlGroup {
                        formatButton("Bold", systemImage: "bold", action: .bold)
                        formatButton("Italic", systemImage: "italic", action: .italic)
                        formatButton("Underline", systemImage: "underline", action: .underline)
                        formatButton("Strikethrough", systemImage: "strikethrough", action: .strikethrough)
                    }

                    ControlGroup {
                        Button {
                            store.applyTextStyleAction(.superscript)
                        } label: {
                            Text("x²")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .accessibilityLabel("Superscript")
                        .help("Superscript")

                        Button {
                            store.applyTextStyleAction(.subscriptText)
                        } label: {
                            Text("x₂")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .accessibilityLabel("Subscript")
                        .help("Subscript")
                    }

                    Menu {
                        Section("Alignment") {
                        ForEach(TextAlignModel.allCases) { alignment in
                            Button {
                                store.updateSelected { $0.textAlignment = alignment }
                            } label: {
                                if selected.textAlignment == alignment {
                                    Label(alignment.rawValue.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(alignment.rawValue.capitalized)
                                }
                            }
                        }
                        }

                        Divider()

                        Section("Direction") {
                            Button("Horizontal") {
                                store.applySelectedTextOrientation(vertical: false)
                            }
                            Button("Vertical") {
                                store.applySelectedTextOrientation(vertical: true)
                            }
                        }

                        Divider()

                        Button("Clear Formatting", systemImage: "eraser") {
                            store.applyTextStyleAction(.clearFormatting)
                        }
                    } label: {
                        Image(systemName: alignmentIcon(selected.textAlignment))
                    }
                    .help("Alignment, Direction, and Clear Formatting")

                    toolbarColorWell(
                        title: "Text Color",
                        selection: Binding(
                            get: { store.selectedElement?.foreground.color ?? .black },
                            set: { store.applyTextStyleAction(.textColor(RGBAColor($0))) }
                        )
                    )

                    toolbarColorWell(
                        title: "Highlight",
                        selection: Binding(
                            get: { highlightColor },
                            set: { color in
                                highlightColor = color
                                store.applyTextStyleAction(.highlightColor(RGBAColor(color)))
                            }
                        )
                    )

                    Button {
                        emojiPresented.toggle()
                    } label: {
                        Label("Emoji", systemImage: "face.smiling")
                            .labelStyle(.iconOnly)
                    }
                    .help("Insert Emoji")
                    .popover(isPresented: $emojiPresented, arrowEdge: .bottom) {
                        EmojiPicker(store: store, isPresented: $emojiPresented)
                            .padding(12)
                            .frame(width: 276)
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 7)
                .padding(.vertical, 7)
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
            )
            .accessibilityIdentifier("textFormattingToolbar")
        }
    }

    private func formatButton(
        _ title: String,
        systemImage: String,
        action: TextStyleAction
    ) -> some View {
        Button {
            store.applyTextStyleAction(action)
        } label: {
            Image(systemName: systemImage)
        }
        .accessibilityLabel(title)
        .help(title)
    }

    private func toolbarColorWell(
        title: String,
        selection: Binding<Color>
    ) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            ColorPicker(title, selection: selection, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 28)
        }
        .help(title)
    }

    private func alignmentIcon(_ alignment: TextAlignModel) -> String {
        switch alignment {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
}

struct EmojiPicker: View {
    @ObservedObject var store: DocumentStore
    @Binding var isPresented: Bool

    private let emojis = [
        "🧬", "🔬", "🧪", "🧫", "⚗️", "🦠",
        "✅", "⚠️", "❌", "⭐️", "🔥", "💧",
        "❄️", "☀️", "🌙", "❤️", "🟢", "🔴",
        "📌", "📦", "🏷️", "🧠", "💊", "🩸"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Insert Emoji")
                .font(.system(size: 13, weight: .semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 6),
                spacing: 5
            ) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        store.insertQuickTextPreset(emoji)
                        isPresented = false
                    } label: {
                        Text(emoji)
                            .font(.system(size: 19))
                            .frame(width: 30, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .help("Insert \(emoji)")
                }
            }

            Divider()

            Button("More Symbols…") {
                isPresented = false
                store.showEmojiPicker()
            }
            .controlSize(.small)
        }
    }
}

struct EditorPane: View {
    @ObservedObject var store: DocumentStore
    @State private var compactOutputPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.canvasMode == .label ? "Label Editor" : "Page Preview")
                        .font(.system(size: 15, weight: .semibold))
                    Text(store.canvasMode == .label ? "Click the label and type." : "Full-sheet output preview.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Label(store.document.formatCode ?? store.document.sheet.name, systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                    if let currentFormat = store.currentFormat {
                        Text(currentFormat.family.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if store.canvasMode == .label {
                HStack(spacing: 8) {
                    Text("Print spec:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(currentPrintSpec)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
            }

            if store.canvasMode == .label,
               store.selectedElement?.type == .text {
                TextFormattingToolbar(store: store)
                    .padding(.horizontal, 10)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                editorGradientTop(),
                                editorGradientBottom()
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if store.canvasMode == .label {
                    // The preview column scales with the pane instead of a
                    // fixed 420pt, which clipped it when the window shrank.
                    GeometryReader { proxy in
                        if proxy.size.width >= 720 {
                            HStack(spacing: 0) {
                                SingleLabelCanvas(store: store)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Divider()
                                    .padding(.vertical, 18)

                                LivePagePreviewPanel(store: store)
                                    .frame(width: min(380, max(240, proxy.size.width * 0.36)))
                                    .frame(maxHeight: .infinity)
                            }
                        } else {
                            ZStack(alignment: .topTrailing) {
                                SingleLabelCanvas(store: store)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Button {
                                    compactOutputPresented.toggle()
                                } label: {
                                    Label("Output", systemImage: "printer")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(10)
                                .popover(isPresented: $compactOutputPresented, arrowEdge: .trailing) {
                                    LivePagePreviewPanel(store: store)
                                        .frame(width: 360, height: 620)
                                        .background(appPanelBackground())
                                }
                            }
                        }
                    }
                } else {
                    PagePreviewCanvas(store: store)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(appChromeBackground().opacity(0.98))
        .accessibilityIdentifier("editorPane")
    }

    private var currentPrintSpec: String {
        let selectedText = store.selectedElement?.type == .text ? store.selectedElement : store.document.elements.first(where: { $0.type == .text })
        if let selectedText {
            let width = String(format: "%.2f", selectedText.frame.width)
            let height = String(format: "%.2f", selectedText.frame.height)
            return "\(selectedText.fontName) size \(selectedText.fontSize) · box \(width) x \(height) mm"
        }
        return "No text object selected"
    }
}

enum ObjectInspectorSection: String, CaseIterable, Identifiable {
    case content
    case style

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum PageInspectorSection: String, CaseIterable, Identifiable {
    case print
    case object

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct InspectorView: View {
    @ObservedObject var store: DocumentStore
    // Remembered per user: these are set once and then ignored for weeks.
    @AppStorage("inspector.notesExpanded") private var notesExpanded = false
    @AppStorage("inspector.wifiExpanded") private var wifiExpanded = false
    @AppStorage("inspector.snippetsExpanded") private var snippetsExpanded = false
    @AppStorage("inspector.objectSection") private var objectSectionRaw = ObjectInspectorSection.content.rawValue
    @AppStorage("inspector.pageSection") private var pageSectionRaw = PageInspectorSection.print.rawValue

    private var objectSection: ObjectInspectorSection {
        ObjectInspectorSection(rawValue: objectSectionRaw) ?? .content
    }

    private var pageSection: PageInspectorSection {
        PageInspectorSection(rawValue: pageSectionRaw) ?? .print
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.canvasMode != .label {
                Picker("Inspector section", selection: $pageSectionRaw) {
                    ForEach(PageInspectorSection.allCases) { section in
                        Text(section.label).tag(section.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .padding(10)

                Divider()
            }

            if store.canvasMode != .label {
                if pageSection == .print {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            CompactNumberingSection(store: store)
                            CompactFrameSection(store: store)
                        }
                        .padding(10)
                    }
                } else {
                    objectInspector
                }

                Divider()
                CaptureQueueBar(store: store)
            } else {
                objectInspector
            }
        }
        .background(appPanelBackground())
        .accessibilityIdentifier("inspector")
    }

    private var objectInspector: some View {
        VStack(spacing: 0) {
            if let selected = store.selectedElement {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Object name", text: selectedBinding(\.name, defaultValue: ""))
                            .controlSize(.small)

                        Text(selected.type.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.10))
                            )
                    }

                    if selected.type != .rectangle {
                        Picker("Object inspector", selection: $objectSectionRaw) {
                            ForEach(ObjectInspectorSection.allCases) { section in
                                Text(section.label).tag(section.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    }
                }
                .padding(10)

                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let selected = store.selectedElement {
                        if selected.type == .rectangle {
                            selectionStyle(selected)
                        } else {
                            switch objectSection {
                            case .content:
                                selectionContent(selected)
                            case .style:
                                selectionStyle(selected)
                            }
                        }
                    } else {
                        GroupBox("Selection") {
                            Text("Select a layer or click an object on the label to edit it.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    projectSettings
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private func selectionContent(_ selected: LabelElement) -> some View {
        GroupBox("Content") {
            VStack(alignment: .leading, spacing: 8) {
                if selected.type == .text || selected.type == .qrCode || selected.type == .code128 {
                    TextEditor(text: selectedBinding(\.content, defaultValue: ""))
                        .font(.system(size: 12))
                        .frame(height: 96)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )

                    HStack(spacing: 7) {
                        Menu("Insert Token") {
                            ForEach(mergeTokens, id: \.self) { token in
                                Button(token) {
                                    store.insertQuickTextPreset(token)
                                }
                            }
                        }

                        if selected.type == .text {
                            Menu("Text Snippets") {
                                ForEach(store.quickTextPresets, id: \.self) { preset in
                                    Button(preset) {
                                        store.insertQuickTextPreset(preset)
                                    }
                                }
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)

                    if selected.type == .text {
                        DisclosureGroup("Manage Text Snippets", isExpanded: $snippetsExpanded) {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(store.quickTextPresets, id: \.self) { preset in
                                    HStack(spacing: 6) {
                                        Text(preset)
                                            .font(.system(size: 10))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Button {
                                            store.removeQuickTextPreset(preset)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("Remove snippet")
                                    }
                                }

                                HStack(spacing: 6) {
                                    TextField("New snippet", text: $store.newQuickTextPreset)
                                    Button("Save") { store.addQuickTextPreset() }
                                        .buttonStyle(.borderedProminent)
                                }
                                .controlSize(.small)
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 10, weight: .semibold))
                    }
                } else if selected.type == .image {
                    Button("Choose Image…", action: store.pickImageForSelected)
                } else {
                    Text("Shapes have no editable content. Use Style to set fill, stroke, and corner radius.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func selectionStyle(_ selected: LabelElement) -> some View {
        if store.canvasMode != .label, selected.type == .text {
            Button {
                store.canvasMode = .label
                store.selectElement(selected.id, beginEditing: true)
            } label: {
                Label("Edit Text & Rich Formatting", systemImage: "textformat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }

        if selected.type == .text, !fontFamilyIsAvailable(selected.fontName) {
            Label(
                "‘\(selected.fontName)’ isn't installed; text uses a fallback and may shift.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        GroupBox("Appearance") {
            VStack(alignment: .leading, spacing: 9) {
                if selected.type == .image {
                    Picker("Scaling", selection: selectedBinding(\.imageScaleMode, defaultValue: .fit)) {
                        ForEach(ImageScaleMode.allCases) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 74), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if selected.type == .qrCode || selected.type == .code128 {
                        CompactColorField(
                            title: "Foreground",
                            selection: selectedColorBinding(\.foreground, defaultValue: .black)
                        )
                    }
                    CompactColorField(
                        title: "Background",
                        selection: selectedColorBinding(\.background, defaultValue: .clear)
                    )
                    CompactColorField(
                        title: "Stroke",
                        selection: selectedColorBinding(\.stroke, defaultValue: .clear)
                    )
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    CompactDecimalField(
                        title: "Stroke",
                        unit: "pt",
                        value: selectedBinding(\.strokeWidth, defaultValue: 0),
                        step: 0.25,
                        range: 0...100
                    )
                    CompactDecimalField(
                        title: "Corner",
                        unit: "mm",
                        value: selectedBinding(\.cornerRadiusMM, defaultValue: 0),
                        step: 0.25,
                        range: 0...100
                    )
                }
            }
        }
    }

    private var mergeTokens: [String] {
        ["{{serial}}", "{{serial_raw}}", "{{set}}", "{{index_in_set}}", "{{page}}", "{{slot}}", "{{row}}", "{{date}}"]
            + (store.document.dataTable?.headers.map { "{{\($0)}}" } ?? [])
    }

    private var projectSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Project Notes", isExpanded: $notesExpanded) {
                TextEditor(text: documentBinding(\.notes))
                    .font(.system(size: 12))
                    .frame(height: 88)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.top, 6)
            }

            DisclosureGroup("Wi-Fi Print", isExpanded: $wifiExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Switch Wi-Fi on Print", isOn: printBinding(\.enabled))
                    TextField("Wi-Fi Service", text: printStringBinding(\.wifiService))
                    TextField("Printer SSID", text: printStringBinding(\.printerSSID))
                        .disabled(!store.document.printAutomation.enabled)
                    SecureField("Printer Wi-Fi Password", text: printStringBinding(\.printerPassword))
                        .disabled(!store.document.printAutomation.enabled)
                    Toggle("Return to previous Wi-Fi", isOn: printBinding(\.reconnectToPreviousWiFi))
                        .disabled(!store.document.printAutomation.enabled)
                    TextField("Restore SSID (empty = auto)", text: Binding(
                        get: { store.document.printAutomation.restoreSSID ?? "" },
                        set: { newValue in
                            store.updateDocument { document in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                document.printAutomation.restoreSSID = trimmed.isEmpty ? nil : trimmed
                            }
                        }
                    ))
                    .disabled(!store.document.printAutomation.enabled || !store.document.printAutomation.reconnectToPreviousWiFi)

                    NumberRow(
                        title: "Settle time",
                        value: printDoubleBinding(\.settleSeconds),
                        suffix: "sec"
                    )
                    .opacity(store.document.printAutomation.enabled ? 1 : 0.5)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], spacing: 6) {
                        Button("Auto Fill", action: store.autofillPrintAutomationSettings)
                        Button("Save Wi-Fi", action: store.savePrintAutomationSettings)
                            .buttonStyle(.borderedProminent)
                        Button("Connect Test", action: store.testPrintAutomationConnection)
                    }
                    .controlSize(.small)

                    Text("Current: \(store.currentWiFiSSID) · \(store.wifiTestStatus)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
        }
    }

    private func documentBinding<Value>(_ keyPath: WritableKeyPath<LabelDocument, Value>) -> Binding<Value> {
        Binding(
            get: { store.document[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func selectedBinding<Value>(_ keyPath: WritableKeyPath<LabelElement, Value>, defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { store.selectedElement?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                store.updateSelected { element in
                    element[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func selectedColorBinding(_ keyPath: WritableKeyPath<LabelElement, RGBAColor>, defaultValue: RGBAColor) -> Binding<Color> {
        Binding(
            get: { store.selectedElement?[keyPath: keyPath].color ?? defaultValue.color },
            set: { newColor in
                store.updateSelected { element in
                    element[keyPath: keyPath] = RGBAColor(newColor)
                }
            }
        )
    }

    private func printBinding(_ keyPath: WritableKeyPath<PrintAutomationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.document.printAutomation[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.printAutomation[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func printStringBinding(_ keyPath: WritableKeyPath<PrintAutomationSettings, String>) -> Binding<String> {
        Binding(
            get: { store.document.printAutomation[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.printAutomation[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func printDoubleBinding(_ keyPath: WritableKeyPath<PrintAutomationSettings, Double>) -> Binding<Double> {
        Binding(
            get: { store.document.printAutomation[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.printAutomation[keyPath: keyPath] = newValue
                }
            }
        )
    }
}

struct PrintQueueSection: View {
    @ObservedObject var store: DocumentStore
    var showsCaptureControls = true

    private var batches: [PrintBatch] {
        store.document.printBatches
    }

    var body: some View {
        GroupBox("Capture Queue") {
            VStack(alignment: .leading, spacing: 10) {
                if showsCaptureControls {
                    Text("Capture freezes the current label, merge data, numbering, page, and start position.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text("Current setup")
                        Spacer()
                        Text("\(store.document.currentSetupLabelCount) label(s)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11, weight: .semibold))

                    Button {
                        store.enqueueCurrentLabel()
                    } label: {
                        Label("Capture Current Setup", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canCaptureCurrentLabel)
                }

                if let issue = store.captureQueueIssue
                    ?? store.pendingDraftIssueMessage {
                    Text(issue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.document.hasQueuedLabels,
                          store.pendingDraftPageIndex == nil {
                    Text("Click an empty label position to stage the next capture.")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if batches.isEmpty {
                    Text("No captured setups yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    HStack {
                        Text("\(store.document.queuedLabelCount) label(s)")
                        Spacer()
                        Text("\(store.document.pageCount) page(s)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(Array(batches.enumerated()), id: \.element.id) { indexedBatch in
                                let index = indexedBatch.offset
                                let batch = indexedBatch.element
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 8) {
                                        Text("\(index + 1)")
                                            .font(.system(size: 10, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Circle().fill(Color.accentColor))

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(batch.name)
                                                .font(.system(size: 11, weight: .semibold))
                                                .lineLimit(2)
                                            Text(captureSummary(for: batch))
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer(minLength: 4)

                                        Button {
                                            store.movePrintBatch(id: batch.id, by: -1)
                                        } label: {
                                            Image(systemName: "chevron.up")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == 0)
                                        .help("Move earlier")

                                        Button {
                                            store.movePrintBatch(id: batch.id, by: 1)
                                        } label: {
                                            Image(systemName: "chevron.down")
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == batches.count - 1)
                                        .help("Move later")

                                        Button {
                                            store.removePrintBatch(id: batch.id)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red)
                                        .help("Remove from queue")
                                    }

                                }
                                .padding(9)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(appCardBackground())
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 220)

                    HStack {
                        Button("Reset Queue", action: store.clearPrintQueue)
                            .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            store.printAllPages()
                        } label: {
                            Label("Print Captures", systemImage: "printer.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func captureSummary(for batch: PrintBatch) -> String {
        var parts = ["\(batch.quantity) labels"]
        if let start = store.document.capturedStartPosition(for: batch) {
            parts.append(
                "page \(start.pageIndex + 1) \(store.document.coordinateLabel(for: start.slotIndex))"
            )
        }
        if let rows = batch.dataTable?.rows, !rows.isEmpty {
            parts.append("CSV \(rows.count) rows")
            return parts.joined(separator: " · ")
        }
        if let serial = batch.serialSettings, serial.mode == .rangedSets {
            parts.append("\(serial.countPerSet) × \(max(1, serial.repeatSets)) sets")
            return parts.joined(separator: " · ")
        }
        parts.append("selected area")
        return parts.joined(separator: " · ")
    }
}

struct CaptureQueueBar: View {
    @ObservedObject var store: DocumentStore
    @State private var queuePresented = false

    private var batches: [PrintBatch] {
        store.document.printBatches
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let issue = store.captureQueueIssue ?? store.pendingDraftIssueMessage {
                Text(issue)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if store.document.hasQueuedLabels,
                      store.pendingDraftPageIndex == nil {
                Text("Choose an empty position for the next capture.")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CURRENT")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text("\(store.document.currentSetupLabelCount) labels")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }

                Spacer(minLength: 4)

                Button {
                    store.enqueueCurrentLabel()
                } label: {
                    Label("Capture", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canCaptureCurrentLabel)

                Button {
                    queuePresented.toggle()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Queue \(batches.count)", systemImage: "tray.full")
                        Label("\(batches.count)", systemImage: "tray.full")
                    }
                }
                .buttonStyle(.bordered)
                .help("Open Capture Queue")
                .popover(isPresented: $queuePresented, arrowEdge: .bottom) {
                    PrintQueueSection(store: store, showsCaptureControls: false)
                        .padding(12)
                        .frame(width: 380)
                        .frame(minHeight: 180, maxHeight: 520)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(appPanelBackground())
        .accessibilityIdentifier("captureQueueBar")
    }
}

struct OfficialFormatChooser: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Official Format")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Search all \(store.officialFormats.count) iLabel formats")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                TextField("Search code, label size, or sheet layout", text: $store.formatSearchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Family", selection: $store.selectedFamilyFilter) {
                    Text("All Families").tag(Optional<ProductFamily>.none)
                    ForEach(ProductFamily.allCases) { family in
                        Text(family.label).tag(Optional(family))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            HStack {
                Text("\(store.filteredFormats.count) matches")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let code = store.document.formatCode {
                    Text("Current · \(code)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List(store.filteredFormats) { format in
                Button {
                    store.applyOfficialFormat(code: format.code)
                    dismiss()
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Text(format.code)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .frame(width: 58, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(format.sizeSummary)
                                .font(.system(size: 12, weight: .medium))
                            Text(format.detailSummary)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(format.family.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)

                        if store.document.formatCode == format.code {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
        }
        .background(appPanelBackground())
    }
}

/// The full font menu holds hundreds of families and the inspector body runs
/// on every keystroke; behind .equatable() the 300-item picker is only
/// rebuilt when the selected element's font actually changes.
struct FontFamilyPicker: View, Equatable {
    let fontName: String
    var width: CGFloat = 118
    let onSelect: (String) -> Void

    static func == (lhs: FontFamilyPicker, rhs: FontFamilyPicker) -> Bool {
        lhs.fontName == rhs.fontName && lhs.width == rhs.width
    }

    var body: some View {
        // While the inline editor is open a selection applies to the dragged
        // range only (like B/I/U); otherwise it restyles the whole element.
        Picker("Font", selection: Binding(get: { fontName }, set: onSelect)) {
            // Keep the element's own font selectable/visible even when it
            // isn't installed on this Mac (e.g. a project from another
            // machine), so the intended font name isn't silently lost.
            if !installedFontFamilies.contains(where: { $0.caseInsensitiveCompare(fontName) == .orderedSame }) {
                Text(fontFamilyIsAvailable(fontName) ? fontName : "\(fontName) (missing)")
                    .tag(fontName)
            }
            ForEach(installedFontFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: width)
    }
}

/// Numeric field that fires `onCommit` only on Enter or focus loss. A
/// formatter-bound `TextField(value:)` can push partially typed numbers
/// through the binding (typing "24" commits 2 then 24), which for font size
/// means an RTF rewrite and full re-render per digit — visible lag and a
/// lossy intermediate scale.
struct CommitNumberField: View {
    let title: String
    let value: Double
    let onCommit: (Double) -> Void
    var step: Double = 0.5
    /// commit() already rejects anything <= 0.1; the arrows honour the same floor.
    var minimum: Double = 0.5

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(title, text: $text)
                .focused($isFocused)
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, newValue in
                    if !isFocused { text = Self.format(newValue) }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
            Stepper(title, onIncrement: { nudge(step) }, onDecrement: { nudge(-step) })
                .labelsHidden()
        }
    }

    /// Steps from what is currently in the box, so arrows continue from a value
    /// typed but not yet committed rather than snapping back to the old one.
    private func nudge(_ delta: Double) {
        let base = Double(text.replacingOccurrences(of: ",", with: ".")) ?? value
        let next = ((base + delta) * 1000).rounded() / 1000
        guard next >= minimum else {
            text = Self.format(value)
            return
        }
        text = Self.format(next)
        onCommit(next)
    }

    private func commit() {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(normalized), parsed > 0.1, abs(parsed - value) > 0.0001 else {
            text = Self.format(value)
            return
        }
        onCommit(parsed)
        text = Self.format(parsed)
    }

    private static func format(_ value: Double) -> String {
        value == floor(value) ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct SingleLabelCanvas: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        GeometryReader { proxy in
            let width = store.document.sheet.labelWidthMM
            let height = store.document.sheet.labelHeightMM
            let scale = min(proxy.size.width / width, proxy.size.height / height) * 0.9
            let firstDraftSlot = store.document.activeSlotIndices.first ?? 0
            let context = store.document.currentSetupMergeContext(
                slotIndex: firstDraftSlot,
                pageIndex: 0
            )

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectElement(nil)
                    }
                GridBackdrop(
                    widthMM: width,
                    heightMM: height,
                    unitScale: scale
                )

                ZStack(alignment: .topLeading) {
                    LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM)
                        .fill(Color.white)
                    if store.document.formatCode == "680" || store.document.sheet.shape == .circle {
                        CircleAlignmentGuides(unitScale: scale, diameterMM: min(width, height))
                    }
                    LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .allowsHitTesting(false)

                    ZStack(alignment: .topLeading) {
                        // Keep a tappable surface above the decorative fill and
                        // stroke but below real elements. An empty element layer
                        // otherwise intercepts the click without starting text
                        // editing, which is especially noticeable on round labels.
                        LabelSurface(
                            shape: store.document.sheet.shape,
                            cornerRadiusMM: store.document.sheet.cornerRadiusMM
                        )
                        .fill(Color.clear)
                        .contentShape(
                            LabelSurface(
                                shape: store.document.sheet.shape,
                                cornerRadiusMM: store.document.sheet.cornerRadiusMM
                            )
                        )
                        .onTapGesture {
                            store.activatePrimaryTextElement()
                        }

                        ForEach(store.document.elements) { element in
                            EditableElementView(
                                element: element,
                                onTextChange: { content, rtf in
                                    store.updateTextElement(id: element.id, content: content, richTextRTF: rtf)
                                },
                                isSelected: store.selectedElementID == element.id,
                                isEditing: store.editingElementID == element.id,
                                context: context,
                                serialSettings: store.document.serial,
                                unitScale: scale,
                                labelWidthMM: width,
                                labelHeightMM: height,
                                usesCircularTextFlow: store.document.sheet.shape == .circle
                                    && element.type == .text
                                    && element.usesCircularTextFlow == true,
                                onSelect: { store.selectElement(element.id) },
                                onBeginEditing: { store.selectElement(element.id, beginEditing: true) },
                                onCommitEditing: { store.finishInlineEditing() },
                                onMove: { frame in
                                    store.updateElement(id: element.id) { selected in
                                        selected.frame = frame
                                    }
                                }
                            )
                        }
                    }
                    .frame(width: scaled(width, by: scale), height: scaled(height, by: scale), alignment: .topLeading)
                    .clipShape(LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM))
                    .contentShape(LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM))

                    if store.document.sheet.shape == .circle,
                       store.selectedElement?.type == .text,
                       store.selectedElement?.usesCircularTextFlow != true {
                        LabelSurface(
                            shape: store.document.sheet.shape,
                            cornerRadiusMM: store.document.sheet.cornerRadiusMM
                        )
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: scaled(width, by: scale), height: scaled(height, by: scale), alignment: .topLeading)
                .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

struct CircleAlignmentGuides: View {
    let unitScale: CGFloat
    let diameterMM: Double

    var body: some View {
        let side = scaled(diameterMM, by: unitScale)
        ZStack {
            Rectangle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: 1, height: side * 0.84)
            Rectangle()
                .fill(Color.accentColor.opacity(0.10))
                .frame(width: side * 0.84, height: 1)
        }
        .frame(width: side, height: side)
        .position(x: side / 2, y: side / 2)
        .allowsHitTesting(false)
    }
}

struct EditableElementView: View {
    let element: LabelElement
    let onTextChange: (String, Data?) -> Void
    let isSelected: Bool
    let isEditing: Bool
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let labelWidthMM: Double
    let labelHeightMM: Double
    let usesCircularTextFlow: Bool
    let onSelect: () -> Void
    let onBeginEditing: () -> Void
    let onCommitEditing: () -> Void
    let onMove: (RectMM) -> Void

    @State private var dragOrigin: RectMM?

    var body: some View {
        let dragGesture = DragGesture(minimumDistance: 1)
            .onChanged { value in
                onSelect()
                if dragOrigin == nil {
                    dragOrigin = element.frame
                }
                guard let dragOrigin else { return }
                let next = RectMM(
                    x: dragOrigin.x + Double(value.translation.width / unitScale),
                    y: dragOrigin.y + Double(value.translation.height / unitScale),
                    width: dragOrigin.width,
                    height: dragOrigin.height
                ).clamped(maxWidth: labelWidthMM, maxHeight: labelHeightMM)
                onMove(next)
            }
            .onEnded { _ in
                dragOrigin = nil
            }

        let baseView = Group {
            if isEditing && element.type == .text {
                InlineEditableTextField(
                    element: element,
                    onTextChange: onTextChange,
                    context: context,
                    serialSettings: serialSettings,
                    unitScale: unitScale,
                    usesCircularTextFlow: usesCircularTextFlow,
                    onCommit: onCommitEditing
                )
            } else {
                ElementRenderableView(
                    element: element,
                    context: context,
                    serialSettings: serialSettings,
                    unitScale: unitScale,
                    usesCircularTextFlow: usesCircularTextFlow
                )
            }
        }

        baseView
            .frame(width: scaled(element.frame.width, by: unitScale), height: scaled(element.frame.height, by: unitScale))
            .overlay(
                TextElementSurface(
                    isCircular: usesCircularTextFlow,
                    cornerRadius: 8
                )
                    .stroke(isSelected ? Color.accentColor : Color.clear, style: .init(lineWidth: 2, dash: [5, 3]))
            )
            .contentShape(
                TextElementSurface(
                    isCircular: usesCircularTextFlow,
                    cornerRadius: 8
                )
            )
            .onTapGesture {
                if element.type == .text {
                    onBeginEditing()
                } else {
                    onSelect()
                }
            }
            .gesture(dragGesture, including: isEditing ? .none : .all)
            .rotationEffect(.degrees(element.rotation))
            .opacity(element.opacity)
            .position(
                x: scaled(element.frame.x + (element.frame.width / 2), by: unitScale),
                y: scaled(element.frame.y + (element.frame.height / 2), by: unitScale)
            )
    }
}

struct InlineEditableTextField: View {
    let element: LabelElement
    let onTextChange: (String, Data?) -> Void
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let usesCircularTextFlow: Bool
    let onCommit: () -> Void

    var body: some View {
        ZStack {
            TextElementSurface(
                isCircular: usesCircularTextFlow,
                cornerRadius: scaled(element.cornerRadiusMM, by: unitScale)
            )
                .fill(element.background.color.opacity(max(element.background.alpha, 0.001)))

            AppKitInlineTextField(
                text: element.content,
                richTextData: element.richTextRTF,
                onTextChange: onTextChange,
                fontName: element.fontName,
                fontSize: max(4, pointsToDisplay(element.fontSize, unitScale: unitScale)),
                storageFontSize: CGFloat(element.fontSize),
                isBold: element.isBold,
                isItalic: element.isItalic,
                isUnderline: element.isUnderline,
                alignment: element.textAlignment,
                foreground: element.foreground.nsColor,
                caretColor: element.foreground.nsColor,
                placeCursorAtStart: element.content.hasPrefix("{{serial}}"),
                usesCircularTextFlow: usesCircularTextFlow,
                circularInsetX: CGFloat(textElementInsetXMM) * unitScale,
                circularInsetY: CGFloat(textElementInsetYMM) * unitScale,
                onCommit: {
                    onCommit()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: element.textAlignment.alignment)
            .padding(
                .horizontal,
                usesCircularTextFlow ? 0 : CGFloat(textElementInsetXMM) * unitScale
            )
            .padding(
                .vertical,
                usesCircularTextFlow ? 0 : CGFloat(textElementInsetYMM) * unitScale
            )
        }
        .overlay(
            TextElementSurface(
                isCircular: usesCircularTextFlow,
                cornerRadius: 8
            )
                .stroke(Color.accentColor, lineWidth: 2.5)
        )
        .shadow(color: Color.accentColor.opacity(0.20), radius: 8)
    }
}

/// Pasting (and text drops) must adopt the label's current typing style.
/// Foreign RTF/HTML from other apps carries its own font runs; once stored,
/// the element-wide Size control scales runs proportionally
/// (`scalingFontSizes`), so a pasted run never converges to the entered
/// size — it just multiplies from the foreign baseline.
final class MatchStylePasteTextView: NSTextView {
    var circularTopInset: CGFloat?
    var circularLayoutSize: CGSize = .zero

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let plain = Self.plainString(from: pboard, incomingType: type) else {
            return super.readSelection(from: pboard, type: type)
        }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound else { return false }
        insertText(plain, replacementRange: range)
        return true
    }

    /// Plain-text equivalent of a rich flavor, or nil when the default
    /// reader should run (plain string, file URLs, images — the latter are
    /// already rejected by `importsGraphics = false`). Rich data without a
    /// companion .string flavor is converted here rather than imported.
    private static func plainString(from pboard: NSPasteboard, incomingType: NSPasteboard.PasteboardType) -> String? {
        guard incomingType == .rtf || incomingType == .rtfd || incomingType == .html else {
            return nil
        }
        if let string = pboard.string(forType: .string) {
            return string
        }
        guard let data = pboard.data(forType: incomingType) else { return nil }
        switch incomingType {
        case .rtf:
            return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        case .rtfd:
            return NSAttributedString(rtfd: data, documentAttributes: nil)?.string
        default:
            return NSAttributedString(html: data, documentAttributes: nil)?.string
        }
    }
}

struct AppKitInlineTextField: NSViewRepresentable {
    let text: String
    let richTextData: Data?
    // Single callback instead of separate text/RTF bindings so both land in
    // one store update; split writes briefly published content with stale or
    // missing RTF, which is what made edits flicker or drop styling.
    let onTextChange: (String, Data?) -> Void
    let fontName: String
    let fontSize: CGFloat
    let storageFontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let isUnderline: Bool
    let alignment: TextAlignModel
    let foreground: NSColor
    let caretColor: NSColor
    let placeCursorAtStart: Bool
    let usesCircularTextFlow: Bool
    let circularInsetX: CGFloat
    let circularInsetY: CGFloat
    let onCommit: () -> Void

    struct ColorSignature: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    struct EditorStyleSignature: Equatable {
        let fontName: String
        let fontSize: CGFloat
        let storageFontSize: CGFloat
        let isBold: Bool
        let isItalic: Bool
        let isUnderline: Bool
        let alignment: TextAlignModel
        let foreground: ColorSignature
        let caret: ColorSignature
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = MatchStylePasteTextView()
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = !usesCircularTextFlow
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = usesCircularTextFlow
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        applyInitialContent(to: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        DispatchQueue.main.async {
            self.configureEditorGeometry(textView)
            self.centerVertically(textView)
            if self.placeCursorAtStart {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Editing can end by the editor view being swapped out (tap outside,
        // finishInlineEditing) without a textDidEndEditing — flush any text
        // the trailing sync hasn't pushed yet or the last keystrokes vanish.
        coordinator.flushPendingSync()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        context.coordinator.parent = self
        let geometryChanged = configureEditorGeometry(textView)

        // While a trailing sync is pending, the editor's storage is strictly
        // newer than the store. Any update arriving in that window (e.g. the
        // 0.6s previewDocument publish re-evaluating this view) carries stale
        // text; applying it would erase the last keystrokes and clamp the
        // cursor to the end of the reverted line.
        if context.coordinator.pendingSyncWorkItem != nil {
            return
        }

        // Completely no-op when this update just echoes what the editor
        // itself produced (every keystroke round-trips through the store).
        // Touching typingAttributes/layout here invalidates the
        // NSTextInputContext, and the input method (Korean IME) then
        // re-syncs its session over XPC on every keystroke — profiled at
        // ~35ms per key, the typing lag.
        if context.coordinator.lastAppliedRichTextData == richTextData,
           context.coordinator.lastAppliedStyle == styleSignature(),
           textView.string == text {
            if geometryChanged {
                centerVertically(textView)
            }
            return
        }

        applyInitialContent(to: textView, coordinator: context.coordinator)
        DispatchQueue.main.async {
            self.centerVertically(textView)
        }
    }

    private func applyInitialContent(to textView: NSTextView, coordinator: Coordinator) {
        // Never rewrite the storage while an IME composition (e.g. Korean
        // Hangul) is in flight — a programmatic replacement here cancels the
        // marked text, so composed characters vanish or commit half-typed.
        if textView.hasMarkedText() {
            applyEditorConfiguration(to: textView)
            return
        }

        let currentStyle = styleSignature()
        let selection = textView.selectedRange()
        var replacedContent = false

        if let attributed = RTFDecodeCache.decode(richTextData),
           attributed.string == text {
            let storageAttributed = normalizedStorageAttributedString(attributed)
            let displayAttributed = scaledAttributedString(storageAttributed, from: storageFontSize, to: fontSize)
            if coordinator.lastAppliedRichTextData != richTextData ||
                coordinator.lastAppliedStyle != currentStyle ||
                textView.string != displayAttributed.string {
                textView.textStorage?.setAttributedString(displayAttributed)
                replacedContent = true
            }
            applyEditorConfiguration(to: textView)
        } else if textView.string != text {
            textView.string = text
            replacedContent = true
        }

        if richTextData == nil {
            if replacedContent || coordinator.lastAppliedStyle != currentStyle {
                applyPlainTextAppearance(to: textView)
            } else {
                applyEditorConfiguration(to: textView)
            }
        }

        if replacedContent {
            restoreSelection(selection, in: textView)
        }
        coordinator.captureState(
            from: textView,
            richTextData: richTextData,
            style: currentStyle
        )
    }

    private func currentTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        return [
            .font: resolvedFont(),
            .foregroundColor: foreground,
            .paragraphStyle: paragraph,
            .underlineStyle: isUnderline ? NSUnderlineStyle.single.rawValue : 0
        ]
    }

    private func applyEditorConfiguration(to textView: NSTextView) {
        let attributes = currentTypingAttributes()
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        textView.insertionPointColor = caretColor
    }

    private func applyPlainTextAppearance(to textView: NSTextView) {
        let attributes = currentTypingAttributes()
        applyEditorConfiguration(to: textView)
        textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: textView.string.utf16.count))
    }

    private func centerVertically(_ textView: NSTextView) {
        guard let textContainer = textView.textContainer, let layoutManager = textView.layoutManager else {
            return
        }
        if usesCircularTextFlow {
            configureEditorGeometry(textView)
            let size = textView.enclosingScrollView?.contentSize ?? textView.bounds.size
            guard size.width > 1, size.height > 1 else { return }
            textView.textContainerInset = .zero
            let circularTextView = textView as? MatchStylePasteTextView
            let topInset = CircularTextLayoutRenderer.configureCenteredLayout(
                layoutManager: layoutManager,
                textContainer: textContainer,
                size: size,
                insets: CGSize(width: circularInsetX, height: circularInsetY),
                initialTopInset: circularTextView?.circularLayoutSize == size
                    ? circularTextView?.circularTopInset
                    : nil
            )
            circularTextView?.circularTopInset = topInset
            circularTextView?.circularLayoutSize = size
            return
        }

        if !textContainer.exclusionPaths.isEmpty {
            textContainer.exclusionPaths = []
            let circularTextView = textView as? MatchStylePasteTextView
            circularTextView?.circularTopInset = nil
            circularTextView?.circularLayoutSize = .zero
        }
        layoutManager.ensureLayout(for: textContainer)
        let nsText = textView.string as NSString
        var visibleLength = nsText.length
        while visibleLength > 0 {
            let scalar = nsText.character(at: visibleLength - 1)
            guard scalar == 10 || scalar == 13 else { break }
            visibleLength -= 1
        }

        let usedHeight: CGFloat
        if visibleLength > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: 0, length: visibleLength),
                actualCharacterRange: nil
            )
            usedHeight = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            ).height
        } else {
            usedHeight = 0
        }

        let availableHeight = textView.enclosingScrollView?.contentSize.height ?? textView.bounds.height
        let verticalInset = max(0, (availableHeight - usedHeight) / 2)
        // Re-assigning the same inset still invalidates layout (and pokes the
        // input context), so skip unless the centering actually moved.
        if abs(textView.textContainerInset.height - verticalInset) > 0.5 {
            textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        }
    }

    @discardableResult
    private func configureEditorGeometry(_ textView: NSTextView) -> Bool {
        guard let textContainer = textView.textContainer else { return false }
        if usesCircularTextFlow {
            let size = textView.enclosingScrollView?.contentSize ?? textView.bounds.size
            guard size.width > 1, size.height > 1 else { return false }
            let changed = abs(textView.frame.width - size.width) > 0.5
                || abs(textView.frame.height - size.height) > 0.5
                || textView.isVerticallyResizable
                || !textContainer.heightTracksTextView
            if changed {
                textView.isVerticallyResizable = false
                textView.frame = CGRect(origin: .zero, size: size)
                textView.minSize = size
                textView.maxSize = size
                textContainer.containerSize = size
                textContainer.widthTracksTextView = true
                textContainer.heightTracksTextView = true
            }
            return changed
        }

        let changed = !textView.isVerticallyResizable
            || textContainer.heightTracksTextView
            || !textContainer.exclusionPaths.isEmpty
        if changed {
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            textContainer.exclusionPaths = []
            let circularTextView = textView as? MatchStylePasteTextView
            circularTextView?.circularTopInset = nil
            circularTextView?.circularLayoutSize = .zero
        }
        return changed
    }

    private func resolvedFont() -> NSFont {
        resolvedNSFont(name: fontName, size: fontSize, isBold: isBold, isItalic: isItalic)
    }

    private func styleSignature() -> EditorStyleSignature {
        EditorStyleSignature(
            fontName: fontName,
            fontSize: fontSize,
            storageFontSize: storageFontSize,
            isBold: isBold,
            isItalic: isItalic,
            isUnderline: isUnderline,
            alignment: alignment,
            foreground: colorSignature(foreground),
            caret: colorSignature(caretColor)
        )
    }

    private func colorSignature(_ color: NSColor) -> ColorSignature {
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return ColorSignature(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    private func restoreSelection(_ selection: NSRange, in textView: NSTextView) {
        let maximumLocation = textView.string.utf16.count
        let location = min(selection.location, maximumLocation)
        let length = min(selection.length, max(0, maximumLocation - location))
        textView.setSelectedRange(NSRange(location: location, length: length))
    }

    private func storageRTFData(from textView: NSTextView) -> Data? {
        guard let textStorage = textView.textStorage else { return nil }
        let storageAttributed = scaledAttributedString(textStorage, from: fontSize, to: storageFontSize)
        guard let data = storageAttributed.rtf(
            from: NSRange(location: 0, length: storageAttributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else { return nil }
        // This payload is re-read on the same keystroke (content.didSet, the
        // preview slots, updateNSView); seeding skips those full RTF parses.
        RTFDecodeCache.seed(storageAttributed, for: data)
        return data
    }

    private func scaledAttributedString(_ attributed: NSAttributedString, from sourceSize: CGFloat, to targetSize: CGFloat) -> NSAttributedString {
        let source = max(sourceSize, 0.1)
        let target = max(targetSize, 0.1)
        let scale = target / source
        let mutable = NSMutableAttributedString(attributedString: attributed)
        // Enumerate the source, not `mutable`: mutating the string being
        // enumerated can re-visit ranges and scale twice.
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length), options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            mutable.addAttribute(.font, value: font.withSize(max(0.1, font.pointSize * scale)), range: range)
        }
        return mutable
    }

    /// Re-derives run attributes from the element-wide style: color and
    /// alignment come from the inspector, so they override every run;
    /// per-run font (family + size) and bold/italic/underline (selection
    /// styling) survive. Keeping the runs' own color meant inspector changes
    /// applied only to newly typed characters, never to the existing text.
    private func normalizedStorageAttributedString(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // Per-selection colors are the one case where a run outranks the
        // element-wide color; see LabelElement.usesPerRunForegroundColor.
        let keepRunColors = LabelElement.usesPerRunForegroundColor(attributed)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        mutable.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var updated = attributes
            // Run fonts (family AND size) are per-selection styling and stay
            // untouched; only font-less runs fall back to the element style.
            if attributes[.font] == nil {
                updated[.font] = resolvedNSFont(name: fontName, size: max(0.1, storageFontSize), isBold: isBold, isItalic: isItalic)
            }
            if !keepRunColors || attributes[.foregroundColor] == nil {
                updated[.foregroundColor] = foreground
            }
            updated[.paragraphStyle] = paragraph
            if updated[.underlineStyle] == nil {
                updated[.underlineStyle] = isUnderline ? NSUnderlineStyle.single.rawValue : 0
            }
            mutable.setAttributes(updated, range: range)
        }
        return mutable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AppKitInlineTextField
        weak var textView: NSTextView?
        var presetObserver: NSObjectProtocol?
        var styleObserver: NSObjectProtocol?
        var emojiObserver: NSObjectProtocol?
        var lastSelectedRange = NSRange(location: 0, length: 0)
        var lastAppliedRichTextData: Data?
        var lastAppliedStyle: EditorStyleSignature?
        var pendingSyncWorkItem: DispatchWorkItem?

        init(parent: AppKitInlineTextField) {
            self.parent = parent
            super.init()
            presetObserver = NotificationCenter.default.addObserver(
                forName: quickTextInsertNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let preset = notification.object as? String,
                    let textView = self.textView
                else { return }

                let range = textView.selectedRange()
                if let textStorage = textView.textStorage {
                    textStorage.replaceCharacters(in: range, with: preset)
                    let insertionLocation = range.location + (preset as NSString).length
                    textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
                    self.syncBindings(from: textView)
                    self.parent.centerVertically(textView)
                }
            }
            styleObserver = NotificationCenter.default.addObserver(
                forName: textStyleActionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let self,
                    let request = notification.object as? TextStyleActionRequest,
                    let textView = self.textView
                else { return }
                self.applyStyle(request, to: textView)
            }
            emojiObserver = NotificationCenter.default.addObserver(
                forName: showEmojiPickerNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let textView = self?.textView else { return }
                textView.window?.makeFirstResponder(textView)
                DispatchQueue.main.async {
                    NSApp.orderFrontCharacterPalette(nil)
                }
            }
        }

        deinit {
            if let presetObserver {
                NotificationCenter.default.removeObserver(presetObserver)
            }
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
            }
            if let emojiObserver {
                NotificationCenter.default.removeObserver(emojiObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.centerVertically(textView)
            // Don't push to the store on every keystroke: the editor owns the
            // text while it's open, and each push costs an RTF encode plus a
            // whole-window SwiftUI diff — and stretches the Korean IME's
            // per-key XPC round trip. A short trailing sync keeps the rest of
            // the app close behind; every exit path flushes synchronously.
            scheduleSync(from: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            syncBindings(from: textView)
        }

        private func scheduleSync(from textView: NSTextView) {
            pendingSyncWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingSyncWorkItem = nil
                self.syncBindings(from: textView)
            }
            pendingSyncWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }

        func flushPendingSync() {
            guard pendingSyncWorkItem != nil, let textView else { return }
            pendingSyncWorkItem?.cancel()
            pendingSyncWorkItem = nil
            syncBindings(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selection = textView.selectedRange()
            if selection.length > 0 {
                lastSelectedRange = selection
            }
        }

        private func applyStyle(_ request: TextStyleActionRequest, to textView: NSTextView) {
            let action = request.action
            guard let textStorage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let hasExplicitSelection = selection.length > 0 || lastSelectedRange.length > 0

            // Font family/size without a dragged selection means "the whole
            // element" — decline so the store applies it element-wide, which
            // also keeps element.fontName/fontSize (and the inspector fields)
            // in sync. B/I/U keep their old apply-to-all behavior here.
            switch action {
            case .fontFamily, .fontSize, .textColor, .clearFormatting:
                guard hasExplicitSelection else { return }
            case .bold, .italic, .underline, .strikethrough, .superscript,
                 .subscriptText, .highlightColor:
                break
            }

            let targetRange = selection.length > 0 ? selection : (lastSelectedRange.length > 0 ? lastSelectedRange : NSRange(location: 0, length: textStorage.length))
            guard targetRange.length > 0 else { return }
            request.handled = true

            textStorage.beginEditing()
            textStorage.enumerateAttributes(in: targetRange, options: []) { attributes, range, _ in
                var updatedAttributes = attributes
                switch action {
                case .bold, .italic:
                    let currentFont = (attributes[.font] as? NSFont) ?? resolvedNSFont(name: self.parent.fontName, size: self.parent.fontSize, isBold: self.parent.isBold, isItalic: self.parent.isItalic)
                    let manager = NSFontManager.shared
                    let trait: NSFontTraitMask = action == .bold ? .boldFontMask : .italicFontMask
                    let hasTrait = manager.traits(of: currentFont).contains(trait)
                    let updated = hasTrait ? manager.convert(currentFont, toNotHaveTrait: trait) : manager.convert(currentFont, toHaveTrait: trait)
                    updatedAttributes[.font] = updated
                case .underline:
                    let current = (attributes[.underlineStyle] as? Int) ?? 0
                    updatedAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
                case .strikethrough, .superscript, .subscriptText,
                     .highlightColor, .clearFormatting:
                    let clearsFormatting = action == .clearFormatting
                    updatedAttributes = RichTextFormatting.applyingAdvancedAction(
                        action,
                        to: attributes,
                        baseFont: resolvedNSFont(
                            name: self.parent.fontName,
                            size: self.parent.fontSize,
                            isBold: clearsFormatting ? false : self.parent.isBold,
                            isItalic: clearsFormatting ? false : self.parent.isItalic
                        ),
                        baseForeground: self.parent.foreground,
                        alignment: self.parent.alignment.nsTextAlignment,
                        baseUnderline: clearsFormatting ? false : self.parent.isUnderline
                    )
                case .fontFamily(let name):
                    let currentFont = (attributes[.font] as? NSFont) ?? resolvedNSFont(name: self.parent.fontName, size: self.parent.fontSize, isBold: self.parent.isBold, isItalic: self.parent.isItalic)
                    let traits = NSFontManager.shared.traits(of: currentFont)
                    updatedAttributes[.font] = resolvedNSFont(
                        name: name,
                        size: currentFont.pointSize,
                        isBold: traits.contains(.boldFontMask),
                        isItalic: traits.contains(.italicFontMask)
                    )
                case .fontSize(let storagePoints):
                    // The editor works in display points; convert the storage
                    // size using the element's own storage→display ratio.
                    let displayScale = self.parent.fontSize / max(self.parent.storageFontSize, 0.1)
                    let currentFont = (attributes[.font] as? NSFont) ?? resolvedNSFont(name: self.parent.fontName, size: self.parent.fontSize, isBold: self.parent.isBold, isItalic: self.parent.isItalic)
                    updatedAttributes[.font] = currentFont.withSize(max(0.5, CGFloat(storagePoints) * displayScale))
                case .textColor(let color):
                    updatedAttributes[.foregroundColor] = color.nsColor
                }
                textStorage.setAttributes(updatedAttributes, range: range)
            }
            textStorage.endEditing()
            self.syncBindings(from: textView)
            self.parent.centerVertically(textView)
            textView.setSelectedRange(targetRange)
            textView.window?.makeFirstResponder(textView)
        }

        func syncBindings(from textView: NSTextView) {
            // A direct sync (style action, preset insert, end editing)
            // supersedes any pending throttled one.
            pendingSyncWorkItem?.cancel()
            pendingSyncWorkItem = nil
            let rtf = parent.storageRTFData(from: textView)
            parent.onTextChange(textView.string, rtf)
            captureState(from: textView, richTextData: rtf, style: parent.styleSignature())
        }

        func captureState(from textView: NSTextView, richTextData: Data?, style: EditorStyleSignature) {
            lastAppliedRichTextData = richTextData
            lastAppliedStyle = style
        }
    }
}

struct LivePagePreviewPanel: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        // The heavy sheet render lives behind .equatable(): the store
        // publishes on every keystroke, but the full-slot grid only needs to
        // re-render when the throttled previewDocument (or the selection)
        // actually changes.
        VStack(spacing: 0) {
            LivePagePreviewBody(
                document: store.previewDocument,
                pageIndex: store.currentPageIndex,
                draftPlan: store.pendingDraftPlan,
                pageCount: store.document.pageCount,
                onTapSlot: { store.selectPlacementStart(at: $0) },
                onDragSlots: { store.selectPlacementRect(from: $0, to: $1) },
                onResetArea: { store.clearPlacementSelection() }
            )
            .equatable()

            Divider()

            // Numbering and capture decide what this preview will print, so
            // they live under it. (This space used to hold a row-by-row print
            // list, which for a numbered run just repeats one label N times.)
            // They stay outside the equatable body above, which is deliberately
            // fed plain values so it does not re-render on every keystroke.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CompactNumberingSection(store: store)
                    CompactFrameSection(store: store)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 300)

            Divider()

            CaptureQueueBar(store: store)
        }
        .accessibilityIdentifier("livePagePreviewPanel")
    }
}

struct LivePagePreviewBody: View, Equatable {
    let document: LabelDocument
    let pageIndex: Int
    let draftPlan: DraftPlacementPlan?
    let pageCount: Int
    let onTapSlot: (Int) -> Void
    let onDragSlots: (Int, Int) -> Void
    let onResetArea: () -> Void

    static func == (lhs: LivePagePreviewBody, rhs: LivePagePreviewBody) -> Bool {
        lhs.document == rhs.document
            && lhs.pageIndex == rhs.pageIndex
            && lhs.draftPlan == rhs.draftPlan
            && lhs.pageCount == rhs.pageCount
    }

    var body: some View {
        let capturedSlotList = document.visiblePreviewSlotIndices(
            pageIndex: pageIndex
        )
        let capturedSlots = Set(capturedSlotList)
        let candidatePlan = document.hasQueuedLabels ? draftPlan : nil
        let draftConflict = candidatePlan.flatMap {
            document.firstPlacementConflict(for: $0)
        }
        let candidateDraftSlots = candidatePlan.map {
            Set(document.draftPreviewSlotIndices(
                pageIndex: pageIndex,
                plan: $0
            ))
        } ?? []
        let validDraftPlan = draftConflict == nil ? candidatePlan : nil
        let visibleDraftSlots = validDraftPlan == nil
            ? Set<Int>()
            : candidateDraftSlots
        let conflictSlots = candidatePlan.map {
            Set(document.draftConflictSlotIndices(
                pageIndex: pageIndex,
                plan: $0
            ))
        } ?? []
        let conflictCount = max(
            conflictSlots.count,
            draftConflict == nil ? 0 : 1
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Print Preview")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Page \(pageIndex + 1)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(document.hasQueuedLabels
                ? "Blue labels are captured for print. Orange labels preview the next uncaptured setup."
                : "This is the full-sheet layout that will be exported or printed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            InteractivePagePreviewCanvas(
                document: document,
                pageIndex: pageIndex,
                selectedSlots: visibleDraftSlots,
                activePrintSlots: capturedSlots,
                validDraftPlan: validDraftPlan,
                conflictSlots: conflictSlots,
                onTapSlot: onTapSlot,
                onDragSlots: onDragSlots
            )
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.8))
                )

            HStack {
                Button("Reset", action: onResetArea)
                    .buttonStyle(.bordered)
                    .help("Reset selected print area")

                Label(
                    document.hasQueuedLabels ? "Captured" : "Print now",
                    systemImage: "circle.fill"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)

                if document.hasQueuedLabels {
                    Label("Next", systemImage: "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                if conflictCount > 0 {
                    Label("Overlap", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                Spacer()

                Text(document.hasQueuedLabels
                    ? "captured \(capturedSlots.count) · next \(candidateDraftSlots.count) · conflicts \(conflictCount)"
                    : "print \(capturedSlots.count) · pages \(pageCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}

struct PagePreviewCanvas: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        PreviewPageCanvas(document: store.document, pageIndex: store.currentPageIndex)
    }
}

struct PreviewPageCanvas: View {
    let document: LabelDocument
    let pageIndex: Int

    var body: some View {
        GeometryReader { proxy in
            let width = document.sheet.pageWidthMM
            let height = document.sheet.pageHeightMM
            let scale = min(proxy.size.width / width, proxy.size.height / height) * 0.94

            ZStack {
                Color.clear
                PageSheetContents(
                    document: document,
                    pageIndex: pageIndex,
                    unitScale: scale,
                    showGuides: true
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct InteractivePagePreviewCanvas: View {
    let document: LabelDocument
    let pageIndex: Int
    let selectedSlots: Set<Int>
    let activePrintSlots: Set<Int>
    let validDraftPlan: DraftPlacementPlan?
    let conflictSlots: Set<Int>
    let onTapSlot: (Int) -> Void
    let onDragSlots: (Int, Int) -> Void

    @State private var dragStartSlot: Int?

    var body: some View {
        GeometryReader { proxy in
            let width = document.sheet.pageWidthMM
            let height = document.sheet.pageHeightMM
            let labelInset: CGFloat = 24
            let scale = min((proxy.size.width - labelInset) / width, (proxy.size.height - labelInset) / height) * 0.96

            ZStack(alignment: .topLeading) {
                ForEach(0..<document.sheet.columns, id: \.self) { column in
                    let frame = document.sheet.slotFrame(column: column, row: 0)
                    Text("\(column + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                        .position(
                            x: labelInset + scaled(frame.x + (frame.width / 2), by: scale),
                            y: 10
                        )
                }

                ForEach(0..<document.sheet.rows, id: \.self) { row in
                    let frame = document.sheet.slotFrame(column: 0, row: row)
                    Text("\(row + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                        .position(
                            x: 10,
                            y: labelInset + scaled(frame.y + (frame.height / 2), by: scale)
                        )
                }

                PageSheetContents(
                    document: document,
                    pageIndex: pageIndex,
                    unitScale: scale,
                    showGuides: true,
                    selectedSlots: selectedSlots,
                    activePrintSlots: activePrintSlots,
                    validDraftPlan: validDraftPlan,
                    conflictSlots: conflictSlots
                )
                .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
                .position(
                    x: labelInset + scaled(width, by: scale) / 2,
                    y: labelInset + scaled(height, by: scale) / 2
                )

                ForEach(0..<document.totalSlotCount, id: \.self) { slotIndex in
                    let row = slotIndex / document.sheet.columns
                    let column = slotIndex % document.sheet.columns
                    let frame = document.sheet.slotFrame(column: column, row: row)

                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: scaled(frame.width, by: scale), height: scaled(frame.height, by: scale))
                        .position(
                            x: labelInset + scaled(frame.x + (frame.width / 2), by: scale),
                            y: labelInset + scaled(frame.y + (frame.height / 2), by: scale)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragStartSlot == nil {
                                        dragStartSlot = slotIndex
                                    }
                                    let isDragging = abs(value.translation.width) >= 2
                                        || abs(value.translation.height) >= 2
                                    if isDragging, let dragStartSlot {
                                        onDragSlots(dragStartSlot, slotIndex)
                                    }
                                }
                                .onEnded { value in
                                    if abs(value.translation.width) < 2 && abs(value.translation.height) < 2 {
                                        onTapSlot(slotIndex)
                                    }
                                    dragStartSlot = nil
                                }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PageSheetContents: View {
    let document: LabelDocument
    let pageIndex: Int
    let unitScale: CGFloat
    let showGuides: Bool
    var selectedSlots: Set<Int> = []
    var activePrintSlots: Set<Int> = []
    var validDraftPlan: DraftPlacementPlan? = nil
    var conflictSlots: Set<Int> = []
    var applyPreviewChrome: Bool = true

    var body: some View {
        let effectivePrintSlots = applyPreviewChrome ? (activePrintSlots.isEmpty
            ? Set(document.visiblePreviewSlotIndices(pageIndex: pageIndex))
            : activePrintSlots) : []

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white)

            ForEach(0..<document.sheet.rows, id: \.self) { row in
                ForEach(0..<document.sheet.columns, id: \.self) { column in
                    let slotIndex = row * document.sheet.columns + column
                    let frame = document.sheet.slotFrame(column: column, row: row)
                    let preview = document.interactivePreviewPayload(
                        slotIndex: slotIndex,
                        pageIndex: pageIndex,
                        validDraftPlan: validDraftPlan
                    )
                    let payload = preview.payload

                    LabelSlotView(
                        document: document,
                        elements: payload.elements,
                        context: payload.context,
                        serialSettings: payload.serialSettings,
                        unitScale: unitScale,
                        showGuides: showGuides,
                        isSelected: selectedSlots.contains(slotIndex),
                        isPrintingNow: effectivePrintSlots.contains(slotIndex),
                        isDraft: preview.source == .draft,
                        hasConflict: conflictSlots.contains(slotIndex),
                        applyPreviewChrome: applyPreviewChrome
                    )
                    .frame(width: scaled(frame.width, by: unitScale), height: scaled(frame.height, by: unitScale))
                    .position(
                        x: scaled(frame.x + (frame.width / 2), by: unitScale),
                        y: scaled(frame.y + (frame.height / 2), by: unitScale)
                    )
                }
            }
        }
        .frame(
            width: scaled(document.sheet.pageWidthMM, by: unitScale),
            height: scaled(document.sheet.pageHeightMM, by: unitScale),
            alignment: .topLeading
        )
    }
}

struct LabelSlotView: View {
    let document: LabelDocument
    let elements: [LabelElement]
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let showGuides: Bool
    var isSelected: Bool = false
    var isPrintingNow: Bool = false
    var isDraft: Bool = false
    var hasConflict: Bool = false
    var applyPreviewChrome: Bool = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            LabelSurface(shape: document.sheet.shape, cornerRadiusMM: document.sheet.cornerRadiusMM)
                .fill(slotBackground)

            LabelSurface(shape: document.sheet.shape, cornerRadiusMM: document.sheet.cornerRadiusMM)
                .stroke(
                    borderColor,
                    style: StrokeStyle(
                        lineWidth: hasConflict || isDraft || isPrintingNow
                            ? 1.4
                            : 1,
                        dash: isDraft ? [2.5, 1.7] : []
                    )
                )

            if context.isActive || !document.hasFiniteMergeRows {
                ZStack(alignment: .topLeading) {
                    ForEach(elements) { element in
                        ElementRenderableView(
                            element: element,
                            context: context,
                            serialSettings: serialSettings,
                            unitScale: unitScale,
                            usesCircularTextFlow: document.sheet.shape == .circle
                                && element.usesCircularTextFlow == true
                        )
                        .frame(width: scaled(element.frame.width, by: unitScale), height: scaled(element.frame.height, by: unitScale))
                        .position(
                            x: scaled(element.frame.x + (element.frame.width / 2), by: unitScale),
                            y: scaled(element.frame.y + (element.frame.height / 2), by: unitScale)
                        )
                        .rotationEffect(.degrees(element.rotation))
                        .opacity(contentOpacity(for: element))
                    }
                }
                // Match the print path, which clips label contents to the
                // label shape (PageRenderer.clip); without this, circle labels
                // preview text that the printer would cut off.
                .clipShape(LabelSurface(shape: document.sheet.shape, cornerRadiusMM: document.sheet.cornerRadiusMM))
            }
        }
    }

    private func contentOpacity(for element: LabelElement) -> Double {
        guard applyPreviewChrome else { return element.opacity }
        if isDraft {
            return element.opacity * 0.78
        }
        return isPrintingNow ? element.opacity : element.opacity * 0.65
    }

    private var slotBackground: Color {
        guard applyPreviewChrome else { return .white }
        if hasConflict {
            return Color.red.opacity(0.10)
        }
        if isDraft {
            return Color.orange.opacity(0.08)
        }
        if isPrintingNow {
            return Color.accentColor.opacity(0.10)
        }
        if isSelected {
            return Color.accentColor.opacity(0.04)
        }
        return Color.white.opacity(0.92)
    }

    private var borderColor: Color {
        guard applyPreviewChrome else { return .clear }
        if hasConflict {
            return Color.red.opacity(0.90)
        }
        if isDraft {
            return Color.orange.opacity(0.90)
        }
        if isPrintingNow {
            return Color.accentColor.opacity(0.65)
        }
        if isSelected {
            return Color.accentColor.opacity(0.28)
        }
        return showGuides ? Color.secondary.opacity(0.22) : .clear
    }
}

/// Draws a text element through the exact print code path
/// (`PageRenderer.drawText`) with only a CTM scale applied, so preview line
/// wrapping matches the printed output glyph-for-glyph. SwiftUI `Text` lays
/// out with a different engine at display-scaled font sizes, which broke
/// lines at slightly different characters than the print render.
struct PrintFidelityTextView: View {
    let element: LabelElement
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let usesCircularTextFlow: Bool

    var body: some View {
        Canvas { graphics, size in
            graphics.withCGContext { cg in
                // Display pixels per print point: layout happens at print
                // point sizes and only the finished drawing is scaled, so
                // wrap decisions are identical to the PDF by construction.
                let scale = unitScale / CGFloat(mmToPointsRatio)
                guard scale > 0, size.width > 0, size.height > 0 else { return }
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: scale, y: -scale)
                let rect = CGRect(
                    x: 0,
                    y: 0,
                    width: mmToPoints(element.frame.width),
                    height: mmToPoints(element.frame.height)
                )
                PageRenderer.drawText(
                    element: element,
                    rect: rect,
                    context: cg,
                    mergeContext: context,
                    serialSettings: serialSettings,
                    usesCircularFlow: usesCircularTextFlow
                )
            }
        }
    }
}

struct ElementRenderableView: View {
    let element: LabelElement
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let usesCircularTextFlow: Bool

    var body: some View {
        switch element.type {
        case .text:
            // Surface fill/stroke, insets, wrapping, alignment, and vertical
            // centering all use the shared print path for exact fidelity.
            PrintFidelityTextView(
                element: element,
                context: context,
                serialSettings: serialSettings,
                unitScale: unitScale,
                usesCircularTextFlow: usesCircularTextFlow
            )
        case .rectangle:
            RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                .fill(element.background.color)
                .overlay(
                    RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                        .stroke(
                            element.stroke.color,
                            lineWidth: max(0.5, pointsToDisplay(element.strokeWidth, unitScale: unitScale))
                        )
                )
        case .image:
            ZStack {
                RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                    .fill(element.background.color)
                if let imageData = element.imageData, let image = NSImage(data: imageData) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: element.imageScaleMode == .fit ? .fit : .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous))
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "photo")
                        Text("Choose Image")
                            .font(.system(size: max(7, CGFloat(8) * unitScale)))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                    .stroke(
                        element.stroke.color,
                        lineWidth: max(0.5, pointsToDisplay(element.strokeWidth, unitScale: unitScale))
                    )
            )
        case .qrCode, .code128:
            ZStack {
                RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                    .fill(element.background.color)
                if let image = CodeImageProvider.makeImage(
                    for: element,
                    context: context,
                    serialSettings: serialSettings,
                    unitScale: unitScale
                ) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .padding(CGFloat(3) * unitScale)
                } else {
                    Text(element.type.label)
                        .font(.system(size: max(8, CGFloat(9) * unitScale), weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                    .stroke(
                        element.stroke.color,
                        lineWidth: max(0.5, pointsToDisplay(element.strokeWidth, unitScale: unitScale))
                    )
            )
        }
    }

}

struct GridBackdrop: View {
    let widthMM: Double
    let heightMM: Double
    let unitScale: CGFloat

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = CGFloat(10) * unitScale
            var x: CGFloat = 0
            while x <= scaled(widthMM, by: unitScale) {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: scaled(heightMM, by: unitScale)))
                context.stroke(line, with: .color(Color.secondary.opacity(0.08)), lineWidth: 1)
                x += step
            }

            var y: CGFloat = 0
            while y <= scaled(heightMM, by: unitScale) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: scaled(widthMM, by: unitScale), y: y))
                context.stroke(line, with: .color(Color.secondary.opacity(0.08)), lineWidth: 1)
                y += step
            }
        }
        .frame(width: scaled(widthMM, by: unitScale), height: scaled(heightMM, by: unitScale))
    }
}

struct LabelSurface: Shape {
    let shape: LabelShape
    let cornerRadiusMM: Double

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .rectangle:
            return Rectangle().path(in: rect)
        case .roundedRectangle:
            return RoundedRectangle(cornerRadius: CGFloat(max(0, cornerRadiusMM)), style: .continuous).path(in: rect)
        case .capsule:
            return Capsule().path(in: rect)
        case .circle:
            // LabelShape.circle represents the full printable oval for custom
            // non-square sizes too, matching the PDF renderer's ellipse.
            return Ellipse().path(in: rect)
        }
    }
}

struct TextElementSurface: Shape {
    let isCircular: Bool
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        if isCircular {
            return Ellipse().path(in: rect)
        }
        return RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        ).path(in: rect)
    }
}

struct DimensionGrid: View {
    let title: String
    let width: Binding<Double>
    let height: Binding<Double>
    var xLabel = "W"
    var yLabel = "H"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                NumberField(label: xLabel, value: width)
                NumberField(label: yLabel, value: height)
            }
        }
    }
}

struct NumberRow: View {
    let title: String
    let value: Binding<Double>
    var suffix: String = "mm"
    /// Nudge size for the arrows. 0.5 suits millimetres and points; callers
    /// whose unit has a different natural grain (opacity, degrees) pass their own.
    var step: Double = 0.5
    var range: ClosedRange<Double>? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            TextField(title, value: value, formatter: UIFormatters.decimal)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
            Stepper(title, value: SteppedValue.binding(value, range: range), step: step)
                .labelsHidden()
            Text(suffix)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }
}

/// Keeps arrow-driven edits inside a field's valid range and off floating-point
/// dust (0.1 + 0.2 style drift shows up immediately when stepping by halves).
enum SteppedValue {
    static func binding(_ value: Binding<Double>, range: ClosedRange<Double>?) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue },
            set: { newValue in
                let rounded = (newValue * 1000).rounded() / 1000
                value.wrappedValue = range.map { min(max(rounded, $0.lowerBound), $0.upperBound) } ?? rounded
            }
        )
    }
}

struct NumberField: View {
    let label: String
    let value: Binding<Double>
    var step: Double = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField(label, value: value, formatter: UIFormatters.decimal)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Stepper(label, value: SteppedValue.binding(value, range: nil), step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

struct CompactStepperField: View {
    let title: String
    let value: Binding<Int>
    let range: ClosedRange<Int>

    private var clampedValue: Binding<Int> {
        Binding(
            get: {
                min(max(value.wrappedValue, range.lowerBound), range.upperBound)
            },
            set: { newValue in
                value.wrappedValue = min(
                    max(newValue, range.lowerBound),
                    range.upperBound
                )
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                TextField(
                    title,
                    value: clampedValue,
                    formatter: UIFormatters.integer
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(maxWidth: .infinity)

                Stepper(title, value: clampedValue, in: range)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }
}

struct CompactTextField: View {
    let title: String
    let text: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }
}

struct CompactDecimalField: View {
    let title: String
    var unit: String? = nil
    let value: Binding<Double>
    var step: Double = 0.5
    var range: ClosedRange<Double>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                if let unit {
                    Text(unit)
                        .fontWeight(.regular)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10))

            HStack(spacing: 3) {
                TextField(title, value: value, formatter: UIFormatters.decimal)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)

                Stepper(
                    title,
                    value: SteppedValue.binding(value, range: range),
                    step: step
                )
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

struct CompactColorField: View {
    let title: String
    let selection: Binding<Color>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ColorPicker(title, selection: selection, supportsOpacity: true)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FlowTokenStack: View {
    let tokens: [String]
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
            ForEach(tokens, id: \.self) { token in
                Button(token) {
                    onTap(token)
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11))
            }
        }
    }
}
