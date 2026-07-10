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

            HSplitView {
                SidebarView(store: store)
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)

                EditorPane(store: store)
                    .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)

                InspectorView(store: store)
                    .frame(minWidth: 320, idealWidth: 340, maxWidth: 400)
            }
        }
        .background(appChromeBackground())
    }
}

struct ToolbarStrip: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        HStack(spacing: 12) {
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
                Button("PDF", action: store.exportPDF)
                    .help("Export the current page as PDF")
                Button("PDF·All", action: store.exportAllPagesPDF)
                    .help("Export every page into one multi-page PDF")
                    .disabled(store.document.pageCount <= 1)
                Button("PNG", action: store.exportPNG)
                Button("Print", action: store.printCurrentPage)
            }

            ToolbarSeparator()

            ControlGroup {
                Button("Text") { store.addElement(.text) }
                Button("Shape") { store.addElement(.rectangle) }
                Button("Image") {
                    store.addElement(.image)
                    store.pickImageForSelected()
                }
                Button("QR") { store.addElement(.qrCode) }
                Button("Barcode") { store.addElement(.code128) }
            }

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
            .pickerStyle(.menu)
            .frame(width: 96)

            ToolbarSeparator()

            ControlGroup {
                Button("Prev") { store.movePage(delta: -1) }
                    .disabled(store.currentPageIndex == 0)

                Text("Page \(store.currentPageIndex + 1) / \(store.document.pageCount)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 96)

                Button("Next") { store.movePage(delta: 1) }
                    .disabled(store.currentPageIndex >= store.document.pageCount - 1)
            }

            Spacer(minLength: 20)

            Text(store.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
    }
}

struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1, height: 18)
    }
}

struct SidebarView: View {
    @ObservedObject var store: DocumentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Project") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Title", text: documentBinding(\.title))

                        if let format = store.currentFormat {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(format.code)
                                        .font(.system(size: 18, weight: .bold, design: .rounded))
                                    Spacer()
                                    Text(format.family.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }

                                Text(format.sizeSummary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                if format.continuous {
                                    Text("Continuous stock: preview uses one repeat cell per page.")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.08))
                            )
                        } else {
                            Text("No official format selected. You can still edit the sheet manually.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Menu("Quick Presets") {
                            ForEach(SheetTemplate.presets) { preset in
                                Button(preset.name) {
                                    store.applyPreset(id: preset.id)
                                }
                            }
                        }
                    }
                }

                OfficialFormatsSection(
                    searchText: $store.formatSearchText,
                    familyFilter: $store.selectedFamilyFilter,
                    filteredFormats: store.filteredFormats,
                    totalCount: store.officialFormats.count,
                    selectedCode: store.document.formatCode,
                    onApply: { store.applyOfficialFormat(code: $0) }
                )
                .equatable()

                GroupBox("Sheet") {
                    VStack(alignment: .leading, spacing: 10) {
                        DimensionGrid(
                            title: "Page",
                            width: sheetBinding(\.pageWidthMM),
                            height: sheetBinding(\.pageHeightMM)
                        )

                        StepperField(title: "Columns", value: sheetBinding(\.columns), range: 1...12)
                        StepperField(title: "Rows", value: sheetBinding(\.rows), range: 1...20)

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

                        NumberRow(title: "Corner mm", value: sheetBinding(\.cornerRadiusMM))

                        Picker("Shape", selection: sheetBinding(\.shape)) {
                            ForEach(LabelShape.allCases) { shape in
                                Text(shape.label).tag(shape)
                            }
                        }
                    }
                }

                GroupBox("Data") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Rows: \(store.document.dataTable?.rows.count ?? 0)")
                            .font(.system(size: 12, weight: .semibold))

                        Text("Tokens: {{serial}}, {{page}}, {{slot}}, {{row}}, {{date}}")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        if let headers = store.document.dataTable?.headers, !headers.isEmpty {
                            FlowTokenStack(tokens: headers.map { "{{\($0)}}" }) { token in
                                store.updateSelected { $0.content += token }
                            }
                        } else {
                            Text("Import CSV to enable column merge tokens.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Objects") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.document.elements) { element in
                            Button {
                                store.selectElement(element.id, beginEditing: element.type == .text)
                            } label: {
                                HStack {
                                    Text(element.type.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(element.name)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(store.selectedElementID == element.id ? Color.accentColor.opacity(0.16) : appCardBackground())
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        HStack {
                            Button("Duplicate", action: store.duplicateSelected)
                                .disabled(store.selectedElement == nil)
                            Button("Delete", action: store.deleteSelected)
                                .disabled(store.selectedElement == nil)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(appPanelBackground())
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

struct EditorPane: View {
    @ObservedObject var store: DocumentStore

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
                    HStack(spacing: 0) {
                        SingleLabelCanvas(store: store)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Divider()
                            .padding(.vertical, 18)

                        LivePagePreviewPanel(store: store)
                            .frame(width: 420)
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    PagePreviewCanvas(store: store)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .background(appChromeBackground().opacity(0.98))
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

struct InspectorView: View {
    @ObservedObject var store: DocumentStore

    private var availableFontFamilies: [String] {
        installedFontFamilies
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selected = store.selectedElement {
                    GroupBox("Selected Object") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Name", text: selectedBinding(\.name, defaultValue: ""))

                            LabeledInfoRow(label: "Type", value: selected.type.label)

                            if selected.type == .text || selected.type == .qrCode || selected.type == .code128 {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Content")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)

                                    TextEditor(text: selectedBinding(\.content, defaultValue: ""))
                                        .font(.system(size: 12))
                                        .frame(height: 84)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                        )

                                    FlowTokenStack(
                                        tokens: ["{{serial}}", "{{serial_raw}}", "{{set}}", "{{index_in_set}}", "{{page}}", "{{slot}}", "{{row}}", "{{date}}"] + (store.document.dataTable?.headers.map { "{{\($0)}}" } ?? [])
                                    ) { token in
                                        store.updateSelected { $0.content += token }
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Quick Presets")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)

                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                                            ForEach(store.quickTextPresets, id: \.self) { preset in
                                                HStack(spacing: 4) {
                                                    Button(preset) {
                                                        store.insertQuickTextPreset(preset)
                                                    }
                                                    .buttonStyle(.bordered)
                                                    .font(.system(size: 11))

                                                    Button {
                                                        store.removeQuickTextPreset(preset)
                                                    } label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .font(.system(size: 11))
                                                    }
                                                    .buttonStyle(.plain)
                                                    .foregroundStyle(.secondary)
                                                }
                                            }
                                        }

                                        HStack(spacing: 8) {
                                            TextField("Add preset", text: $store.newQuickTextPreset)
                                            Button("Save") {
                                                store.addQuickTextPreset()
                                            }
                                            .buttonStyle(.borderedProminent)
                                        }
                                    }
                                }
                            }

                            if selected.type == .image {
                                Button("Choose Image", action: store.pickImageForSelected)
                            }
                        }
                    }

                    GroupBox("Frame") {
                        VStack(alignment: .leading, spacing: 10) {
                            DimensionGrid(
                                title: "Position",
                                width: selectedBinding(\.frame.x, defaultValue: 0),
                                height: selectedBinding(\.frame.y, defaultValue: 0),
                                xLabel: "X",
                                yLabel: "Y"
                            )

                            DimensionGrid(
                                title: "Size",
                                width: selectedBinding(\.frame.width, defaultValue: 10),
                                height: selectedBinding(\.frame.height, defaultValue: 10)
                            )

                            NumberRow(title: "Rotation", value: selectedBinding(\.rotation, defaultValue: 0), suffix: "deg")
                            NumberRow(title: "Opacity", value: selectedBinding(\.opacity, defaultValue: 1))
                        }
                    }

                    GroupBox("Appearance") {
                        VStack(alignment: .leading, spacing: 10) {
                            if selected.type == .text {
                                HStack(alignment: .center, spacing: 10) {
                                    Text("Size")
                                        .font(.system(size: 12))
                                        .frame(width: 32, alignment: .leading)
                                    // Editing + selection → resizes just the
                                    // selection; otherwise the whole element.
                                    CommitNumberField(
                                        title: "Size",
                                        value: store.selectedElement?.fontSize ?? 12,
                                        onCommit: { store.applyTextStyleAction(.fontSize($0)) }
                                    )
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 64)
                                    Text("pt")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)

                                    Spacer(minLength: 8)

                                    Text("Font")
                                        .font(.system(size: 12))
                                    FontFamilyPicker(
                                        fontName: selected.fontName,
                                        onSelect: { store.applyTextStyleAction(.fontFamily($0)) }
                                    )
                                    .equatable()
                                }

                                if !fontFamilyIsAvailable(selected.fontName) {
                                    Label("‘\(selected.fontName)’ isn't installed on this Mac — text falls back to the system font, so its size and position may differ from the original.", systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                HStack(alignment: .center, spacing: 10) {
                                    Button("Bold") {
                                        store.applyTextStyleAction(.bold)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Italic") {
                                        store.applyTextStyleAction(.italic)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Underline") {
                                        store.applyTextStyleAction(.underline)
                                    }
                                    .buttonStyle(.bordered)

                                    Text("Align")
                                        .font(.system(size: 12))
                                    Picker("Align", selection: selectedBinding(\.textAlignment, defaultValue: .center)) {
                                        ForEach(TextAlignModel.allCases) { alignment in
                                            Text(alignment.rawValue.capitalized).tag(alignment)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 96)
                                    Spacer(minLength: 0)
                                }
                            }

                            if selected.type == .image {
                                Picker("Scaling", selection: selectedBinding(\.imageScaleMode, defaultValue: .fit)) {
                                    ForEach(ImageScaleMode.allCases) { mode in
                                        Text(mode.rawValue.capitalized).tag(mode)
                                    }
                                }
                            }

                            ColorRow(title: "Foreground", selection: selectedColorBinding(\.foreground, defaultValue: .black))
                                .opacity(selected.type == .rectangle || selected.type == .image ? 0.4 : 1)
                            ColorRow(title: "Background", selection: selectedColorBinding(\.background, defaultValue: .clear))
                            ColorRow(title: "Stroke", selection: selectedColorBinding(\.stroke, defaultValue: .clear))
                            NumberRow(title: "Stroke pt", value: selectedBinding(\.strokeWidth, defaultValue: 0))
                            NumberRow(title: "Corner mm", value: selectedBinding(\.cornerRadiusMM, defaultValue: 0))
                        }
                    }
                } else {
                    GroupBox("Selection") {
                        Text("Select an object from the canvas or object list to edit it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Numbering + Notes") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Fill Order", selection: placementBinding(\.fillDirection)) {
                            ForEach(PlacementFillDirection.allCases) { direction in
                                Text(direction.label).tag(direction)
                            }
                        }

                        Picker("Mode", selection: serialBinding(\.mode)) {
                            ForEach(SerialMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }

                        StepperField(title: "Start", value: serialBinding(\.start), range: 0...999_999)
                        StepperField(title: "Step", value: serialBinding(\.step), range: 1...999)
                        if store.document.serial.mode == .rangedSets {
                            StepperField(title: "End", value: serialBinding(\.end), range: 0...999_999)
                            StepperField(title: "Repeat Sets", value: serialBinding(\.repeatSets), range: 1...999)
                        }
                        StepperField(title: "Digits", value: serialBinding(\.digits), range: 1...12)

                        HStack(spacing: 8) {
                            TextField("Prefix", text: serialStringBinding(\.prefix))
                            TextField("Suffix", text: serialStringBinding(\.suffix))
                        }

                        if store.document.serial.mode == .rangedSets {
                            Text("Labels: \(store.document.serial.countPerSet) per set · \(store.document.serial.repeatSets) set(s) · total \(store.document.serial.totalGeneratedCount)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Use {{serial}}, {{serial_raw}}, {{set}}, {{index_in_set}}")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Use {{serial}} for continuous numbering")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Project Notes")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            TextEditor(text: documentBinding(\.notes))
                                .font(.system(size: 12))
                                .frame(height: 88)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                                )
                        }
                    }
                }

                GroupBox("Wi-Fi Print") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Switch Wi-Fi on Print", isOn: printBinding(\.enabled))

                        TextField("Wi-Fi Service", text: printStringBinding(\.wifiService))

                        TextField("Printer SSID", text: printStringBinding(\.printerSSID))
                            .disabled(!store.document.printAutomation.enabled)

                        SecureField("Printer Wi-Fi Password", text: printStringBinding(\.printerPassword))
                            .disabled(!store.document.printAutomation.enabled)

                        Toggle("Return to previous Wi-Fi", isOn: printBinding(\.reconnectToPreviousWiFi))
                            .disabled(!store.document.printAutomation.enabled)

                        // macOS 15+ hides the current SSID from apps, so the
                        // pre-print network often can't be captured; this names
                        // the network to fall back to. Empty → the top
                        // non-printer preferred network is used.
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

                        NumberRow(title: "Settle sec", value: printDoubleBinding(\.settleSeconds), suffix: "sec")
                            .opacity(store.document.printAutomation.enabled ? 1 : 0.5)

                        HStack {
                            Button("Auto Fill") {
                                store.autofillPrintAutomationSettings()
                            }
                            .buttonStyle(.bordered)

                            Button("Save Wi-Fi") {
                                store.savePrintAutomationSettings()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Connect Test") {
                                store.testPrintAutomationConnection()
                            }
                            .buttonStyle(.bordered)

                            Spacer()

                            Text("Current: \(store.currentWiFiSSID)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Text("Status: \(store.wifiTestStatus)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        Text("When enabled, Print will switch to the printer SSID, open the macOS print panel, then reconnect to your previous Wi-Fi.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
        .background(appPanelBackground())
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

    private func serialBinding(_ keyPath: WritableKeyPath<SerialSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.document.serial[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.serial[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func serialBinding(_ keyPath: WritableKeyPath<SerialSettings, SerialMode>) -> Binding<SerialMode> {
        Binding(
            get: { store.document.serial[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.serial[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func serialStringBinding(_ keyPath: WritableKeyPath<SerialSettings, String>) -> Binding<String> {
        Binding(
            get: { store.document.serial[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.serial[keyPath: keyPath] = newValue
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

    private func placementBinding(_ keyPath: WritableKeyPath<PlacementSettings, PlacementFillDirection>) -> Binding<PlacementFillDirection> {
        Binding(
            get: { store.document.placement[keyPath: keyPath] },
            set: { newValue in
                store.updateDocument { document in
                    document.placement[keyPath: keyPath] = newValue
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

/// The catalog list is ~180 visible rows out of 1,006 formats and the sidebar
/// body runs on every keystroke; behind .equatable() the list only rebuilds
/// when the search, family filter, or selected format actually changes.
struct OfficialFormatsSection: View, Equatable {
    @Binding var searchText: String
    @Binding var familyFilter: ProductFamily?
    let filteredFormats: [OfficialFormatDefinition]
    let totalCount: Int
    let selectedCode: String?
    let onApply: (String) -> Void

    static func == (lhs: OfficialFormatsSection, rhs: OfficialFormatsSection) -> Bool {
        lhs.searchText == rhs.searchText
            && lhs.familyFilter == rhs.familyFilter
            && lhs.selectedCode == rhs.selectedCode
    }

    var body: some View {
        GroupBox("Official Formats") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Search code or size", text: $searchText)

                Picker("Family", selection: $familyFilter) {
                    Text("All Families").tag(Optional<ProductFamily>.none)
                    ForEach(ProductFamily.allCases) { family in
                        Text(family.label).tag(Optional(family))
                    }
                }
                .pickerStyle(.menu)

                Text("\(filteredFormats.count) matches / \(totalCount) official formats")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(filteredFormats.prefix(180))) { format in
                            Button {
                                onApply(format.code)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(format.code)
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                        Text(format.sizeSummary)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        Text(format.detailSummary)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(selectedCode == format.code ? Color.accentColor.opacity(0.16) : appCardBackground())
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 240, maxHeight: 320)
            }
        }
    }
}

/// The full font menu holds hundreds of families and the inspector body runs
/// on every keystroke; behind .equatable() the 300-item picker is only
/// rebuilt when the selected element's font actually changes.
struct FontFamilyPicker: View, Equatable {
    let fontName: String
    let onSelect: (String) -> Void

    static func == (lhs: FontFamilyPicker, rhs: FontFamilyPicker) -> Bool {
        lhs.fontName == rhs.fontName
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
        .frame(width: 118)
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

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
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
            let context = store.document.mergeContext(slotIndex: 0, pageIndex: store.currentPageIndex)

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
                        .contentShape(LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM))
                        .onTapGesture {
                            store.activatePrimaryTextElement()
                        }
                    if store.document.formatCode == "680" || store.document.sheet.shape == .circle {
                        CircleAlignmentGuides(unitScale: scale, diameterMM: min(width, height))
                    }
                    LabelSurface(shape: store.document.sheet.shape, cornerRadiusMM: store.document.sheet.cornerRadiusMM)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)

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
                    onCommit: onCommitEditing
                )
            } else {
                ElementRenderableView(
                    element: element,
                    context: context,
                    serialSettings: serialSettings,
                    unitScale: unitScale
                )
            }
        }

        baseView
            .frame(width: scaled(element.frame.width, by: unitScale), height: scaled(element.frame.height, by: unitScale))
            .position(
                x: scaled(element.frame.x + (element.frame.width / 2), by: unitScale),
                y: scaled(element.frame.y + (element.frame.height / 2), by: unitScale)
            )
            .rotationEffect(.degrees(element.rotation))
            .opacity(element.opacity)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, style: .init(lineWidth: 2, dash: [5, 3]))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if element.type == .text {
                    onBeginEditing()
                } else {
                    onSelect()
                }
            }
            .gesture(dragGesture, including: isEditing ? .none : .all)
    }
}

struct InlineEditableTextField: View {
    let element: LabelElement
    let onTextChange: (String, Data?) -> Void
    let context: MergeContext
    let serialSettings: SerialSettings
    let unitScale: CGFloat
    let onCommit: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
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
                onCommit: {
                    onCommit()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: element.textAlignment.alignment)
            .padding(.horizontal, CGFloat(textElementInsetXMM) * unitScale)
            .padding(.vertical, CGFloat(textElementInsetYMM) * unitScale)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
        )
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

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.heightTracksTextView = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        applyInitialContent(to: textView, coordinator: context.coordinator)

        scrollView.documentView = textView
        DispatchQueue.main.async {
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
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let availableHeight = textView.bounds.height
        let verticalInset = max(0, floor((availableHeight - usedRect.height) / 2))
        // Re-assigning the same inset still invalidates layout (and pokes the
        // input context), so skip unless the centering actually moved.
        if abs(textView.textContainerInset.height - verticalInset) > 0.5 {
            textView.textContainerInset = NSSize(width: 0, height: verticalInset)
        }
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment.nsTextAlignment
        mutable.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var updated = attributes
            // Run fonts (family AND size) are per-selection styling and stay
            // untouched; only font-less runs fall back to the element style.
            if attributes[.font] == nil {
                updated[.font] = resolvedNSFont(name: fontName, size: max(0.1, storageFontSize), isBold: isBold, isItalic: isItalic)
            }
            updated[.foregroundColor] = foreground
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
        }

        deinit {
            if let presetObserver {
                NotificationCenter.default.removeObserver(presetObserver)
            }
            if let styleObserver {
                NotificationCenter.default.removeObserver(styleObserver)
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
            case .fontFamily, .fontSize:
                guard hasExplicitSelection else { return }
            case .bold, .italic, .underline:
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
        LivePagePreviewBody(
            document: store.previewDocument,
            pageIndex: store.currentPageIndex,
            selectedSlots: Set(store.document.activeSlotIndices),
            pageCount: store.document.pageCount,
            onTapSlot: { store.selectPlacementStart(at: $0) },
            onDragSlots: { store.selectPlacementRect(from: $0, to: $1) },
            onResetArea: { store.clearPlacementSelection() }
        )
        .equatable()
    }
}

struct LivePagePreviewBody: View, Equatable {
    let document: LabelDocument
    let pageIndex: Int
    let selectedSlots: Set<Int>
    let pageCount: Int
    let onTapSlot: (Int) -> Void
    let onDragSlots: (Int, Int) -> Void
    let onResetArea: () -> Void

    static func == (lhs: LivePagePreviewBody, rhs: LivePagePreviewBody) -> Bool {
        lhs.document == rhs.document
            && lhs.pageIndex == rhs.pageIndex
            && lhs.selectedSlots == rhs.selectedSlots
            && lhs.pageCount == rhs.pageCount
    }

    var body: some View {
        let activePrintSlots = Set(document.visiblePreviewSlotIndices(pageIndex: pageIndex))
        let printListEntries = makePrintListEntries(document: document, pageIndex: pageIndex, slots: document.visiblePreviewSlotIndices(pageIndex: pageIndex))

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Print Preview")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Page \(pageIndex + 1)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("This is the full-sheet layout that will be exported or printed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            InteractivePagePreviewCanvas(
                document: document,
                pageIndex: pageIndex,
                selectedSlots: selectedSlots,
                activePrintSlots: activePrintSlots,
                onTapSlot: onTapSlot,
                onDragSlots: onDragSlots
            )
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.8))
                )

            HStack {
                Button("Reset Area", action: onResetArea)
                .buttonStyle(.bordered)

                Label("Blue = print now", systemImage: "rectangle.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("print \(activePrintSlots.count) · selected \(selectedSlots.count) · pages \(pageCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Print List")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(printListEntries.count) item(s)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(printListEntries, id: \.slotIndex) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.coordinate)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .frame(width: 48, alignment: .leading)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.primary)
                                    .font(.system(size: 11))
                                    .lineLimit(3)
                                if let secondary = entry.secondary, !secondary.isEmpty {
                                    Text(secondary)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor).opacity(0.7))
                        )
                    }
                }
            }
            .frame(minHeight: 88, maxHeight: 130)
        }
        .padding(14)
    }

    private func makePrintListEntries(document: LabelDocument, pageIndex: Int, slots: [Int]) -> [PrintListEntry] {
        let textElements = document.elements.filter { $0.type == .text }
        let codeElements = document.elements.filter { $0.type == .qrCode || $0.type == .code128 }

        return slots.compactMap { slotIndex in
            let context = document.mergeContext(slotIndex: slotIndex, pageIndex: pageIndex)
            guard context.isActive || !document.hasFiniteMergeRows else { return nil }

            let textLines = textElements
                .map { MergeRenderer.resolve($0.content, context: context, serialSettings: document.serial) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let codeLines = codeElements
                .map { MergeRenderer.resolve($0.content, context: context, serialSettings: document.serial) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let primary = textLines.first ?? codeLines.first ?? "(empty)"
            let secondaryParts = Array(textLines.dropFirst()) + codeLines.prefix(2)
            let secondary = secondaryParts.isEmpty ? nil : secondaryParts.joined(separator: " · ")

            return PrintListEntry(
                slotIndex: slotIndex,
                coordinate: document.coordinateLabel(for: slotIndex),
                primary: primary,
                secondary: secondary
            )
        }
    }
}

struct PrintListEntry {
    let slotIndex: Int
    let coordinate: String
    let primary: String
    let secondary: String?
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
                    activePrintSlots: activePrintSlots
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
                                .onChanged { _ in
                                    if dragStartSlot == nil {
                                        dragStartSlot = slotIndex
                                    }
                                    if let dragStartSlot {
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

                    LabelSlotView(
                        document: document,
                        context: document.mergeContext(slotIndex: slotIndex, pageIndex: pageIndex),
                        unitScale: unitScale,
                        showGuides: showGuides,
                        isSelected: selectedSlots.contains(slotIndex),
                        isPrintingNow: effectivePrintSlots.contains(slotIndex),
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
    let context: MergeContext
    let unitScale: CGFloat
    let showGuides: Bool
    var isSelected: Bool = false
    var isPrintingNow: Bool = false
    var applyPreviewChrome: Bool = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            LabelSurface(shape: document.sheet.shape, cornerRadiusMM: document.sheet.cornerRadiusMM)
                .fill(slotBackground)

            LabelSurface(shape: document.sheet.shape, cornerRadiusMM: document.sheet.cornerRadiusMM)
                .stroke(borderColor, lineWidth: isPrintingNow ? 1.4 : 1)

            if context.isActive || !document.hasFiniteMergeRows {
                ZStack(alignment: .topLeading) {
                    ForEach(document.elements) { element in
                        ElementRenderableView(
                            element: element,
                            context: context,
                            serialSettings: document.serial,
                            unitScale: unitScale
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
        return isPrintingNow ? element.opacity : element.opacity * 0.65
    }

    private var slotBackground: Color {
        guard applyPreviewChrome else { return .white }
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
                    serialSettings: serialSettings
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

    var body: some View {
        switch element.type {
        case .text:
            ZStack {
                RoundedRectangle(cornerRadius: scaled(element.cornerRadiusMM, by: unitScale), style: .continuous)
                    .fill(element.background.color)
                // Insets, wrapping, alignment, and vertical centering all live
                // inside the shared print path — no SwiftUI padding here.
                PrintFidelityTextView(
                    element: element,
                    context: context,
                    serialSettings: serialSettings,
                    unitScale: unitScale
                )
            }
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
            return Circle().path(in: rect)
        }
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

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            TextField(title, value: value, formatter: UIFormatters.decimal)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
            Text(suffix)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }
}

struct NumberField: View {
    let label: String
    let value: Binding<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(label, value: value, formatter: UIFormatters.decimal)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct StepperField: View {
    let title: String
    let value: Binding<Int>
    let range: ClosedRange<Int>

    private var clampedValue: Binding<Int> {
        Binding(
            get: {
                min(max(value.wrappedValue, range.lowerBound), range.upperBound)
            },
            set: { newValue in
                value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            TextField(title, value: clampedValue, formatter: UIFormatters.integer)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 78)
            Stepper(title, value: clampedValue, in: range)
                .labelsHidden()
        }
    }
}

struct ColorRow: View {
    let title: String
    let selection: Binding<Color>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker(title, selection: selection)
                .labelsHidden()
        }
    }
}

struct LabeledInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 12))
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
