import SwiftUI
import AppKit

let mmToPointsRatio = 72.0 / 25.4

/// Text-element content insets in mm, shared by the canvas, the inline
/// editor, the sheet preview, AND the print/PDF renderer. All surfaces must
/// use the same values or text wraps at different points on screen vs paper.
let textElementInsetXMM = 1.0
let textElementInsetYMM = 0.6

func mmToPoints(_ millimeters: Double) -> CGFloat {
    CGFloat(millimeters * mmToPointsRatio)
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let nsColor = NSColor(color).usingColorSpace(.deviceRGB) ?? .black
        self.red = Double(nsColor.redComponent)
        self.green = Double(nsColor.greenComponent)
        self.blue = Double(nsColor.blueComponent)
        self.alpha = Double(nsColor.alphaComponent)
    }

    var color: Color {
        Color(nsColor: nsColor)
    }

    var nsColor: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let accent = RGBAColor(red: 0.17, green: 0.31, blue: 0.88, alpha: 1)
    static let softGray = RGBAColor(red: 0.94, green: 0.95, blue: 0.98, alpha: 1)
    static let ink = RGBAColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1)
}

struct RectMM: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func clamped(maxWidth: Double, maxHeight: Double) -> RectMM {
        let safeWidth = max(5, min(width, maxWidth))
        let safeHeight = max(5, min(height, maxHeight))
        let safeX = min(max(0, x), max(0, maxWidth - safeWidth))
        let safeY = min(max(0, y), max(0, maxHeight - safeHeight))
        return RectMM(x: safeX, y: safeY, width: safeWidth, height: safeHeight)
    }
}

enum LabelShape: String, Codable, CaseIterable, Identifiable {
    case roundedRectangle
    case rectangle
    case capsule
    case circle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .roundedRectangle:
            return "Rounded"
        case .rectangle:
            return "Rectangle"
        case .capsule:
            return "Capsule"
        case .circle:
            return "Circle"
        }
    }
}

enum ElementType: String, Codable, CaseIterable, Identifiable {
    case text
    case rectangle
    case image
    case qrCode
    case code128

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:
            return "Text"
        case .rectangle:
            return "Shape"
        case .image:
            return "Image"
        case .qrCode:
            return "QR"
        case .code128:
            return "Code128"
        }
    }
}

enum ImageScaleMode: String, Codable, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
}

enum TextAlignModel: String, Codable, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var multilineAlignment: TextAlignment {
        switch self {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }
}

enum CanvasMode: String, CaseIterable, Identifiable {
    case label
    case page

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}

enum AppAppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct SheetTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var pageWidthMM: Double
    var pageHeightMM: Double
    var columns: Int
    var rows: Int
    var labelWidthMM: Double
    var labelHeightMM: Double
    var horizontalGapMM: Double
    var verticalGapMM: Double
    var marginLeftMM: Double
    var marginTopMM: Double
    var shape: LabelShape
    var cornerRadiusMM: Double

    /// The largest axis-aligned rectangle whose corners remain inside the
    /// label boundary. Circular labels use the inscribed rectangle of their
    /// ellipse; other shapes retain the full label bounds.
    var textSafeFrame: RectMM {
        guard shape == .circle else {
            return RectMM(x: 0, y: 0, width: labelWidthMM, height: labelHeightMM)
        }

        let width = labelWidthMM / sqrt(2)
        let height = labelHeightMM / sqrt(2)
        return RectMM(
            x: (labelWidthMM - width) / 2,
            y: (labelHeightMM - height) / 2,
            width: width,
            height: height
        )
    }

    func slotFrame(column: Int, row: Int) -> RectMM {
        let x = marginLeftMM + (Double(column) * (labelWidthMM + horizontalGapMM))
        let y = marginTopMM + (Double(row) * (labelHeightMM + verticalGapMM))
        return RectMM(x: x, y: y, width: labelWidthMM, height: labelHeightMM)
    }

    func matches(_ other: SheetTemplate) -> Bool {
        id == other.id ||
        (
            pageWidthMM == other.pageWidthMM &&
            pageHeightMM == other.pageHeightMM &&
            columns == other.columns &&
            rows == other.rows &&
            labelWidthMM == other.labelWidthMM &&
            labelHeightMM == other.labelHeightMM &&
            horizontalGapMM == other.horizontalGapMM &&
            verticalGapMM == other.verticalGapMM &&
            marginLeftMM == other.marginLeftMM &&
            marginTopMM == other.marginTopMM &&
            shape == other.shape &&
            cornerRadiusMM == other.cornerRadiusMM
        )
    }

    static let presets: [SheetTemplate] = [
        SheetTemplate(
            id: "a4-2x5-shipping",
            name: "A4 Shipping 2x5",
            pageWidthMM: 210,
            pageHeightMM: 297,
            columns: 2,
            rows: 5,
            labelWidthMM: 99.1,
            labelHeightMM: 57,
            horizontalGapMM: 2.8,
            verticalGapMM: 2.5,
            marginLeftMM: 4.5,
            marginTopMM: 4.5,
            shape: .roundedRectangle,
            cornerRadiusMM: 2.4
        ),
        SheetTemplate(
            id: "a4-3x8-address",
            name: "A4 Address 3x8",
            pageWidthMM: 210,
            pageHeightMM: 297,
            columns: 3,
            rows: 8,
            labelWidthMM: 63.5,
            labelHeightMM: 33.9,
            horizontalGapMM: 3,
            verticalGapMM: 2.5,
            marginLeftMM: 6.5,
            marginTopMM: 8,
            shape: .roundedRectangle,
            cornerRadiusMM: 1.8
        ),
        SheetTemplate(
            id: "a4-round-4x5",
            name: "A4 Round 4x5",
            pageWidthMM: 210,
            pageHeightMM: 297,
            columns: 4,
            rows: 5,
            labelWidthMM: 42,
            labelHeightMM: 42,
            horizontalGapMM: 6,
            verticalGapMM: 8.5,
            marginLeftMM: 9,
            marginTopMM: 10,
            shape: .circle,
            cornerRadiusMM: 21
        ),
        SheetTemplate(
            id: "roll-100x50",
            name: "Roll 100 x 50",
            pageWidthMM: 100,
            pageHeightMM: 50,
            columns: 1,
            rows: 1,
            labelWidthMM: 100,
            labelHeightMM: 50,
            horizontalGapMM: 0,
            verticalGapMM: 0,
            marginLeftMM: 0,
            marginTopMM: 0,
            shape: .roundedRectangle,
            cornerRadiusMM: 2.5
        )
    ]

    static let customDefault = SheetTemplate(
        id: "custom",
        name: "Custom",
        pageWidthMM: 210,
        pageHeightMM: 297,
        columns: 2,
        rows: 5,
        labelWidthMM: 95,
        labelHeightMM: 55,
        horizontalGapMM: 4,
        verticalGapMM: 4,
        marginLeftMM: 6,
        marginTopMM: 6,
        shape: .roundedRectangle,
        cornerRadiusMM: 2
    )
}

enum SerialMode: String, Codable, CaseIterable, Identifiable {
    case continuous
    case rangedSets

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuous:
            return "Continuous"
        case .rangedSets:
            return "Range + Sets"
        }
    }
}

struct SerialSettings: Codable, Hashable {
    var mode: SerialMode
    var start: Int
    var step: Int
    var end: Int
    var repeatSets: Int
    var digits: Int
    var prefix: String
    var suffix: String

    var countPerSet: Int {
        guard step > 0, end >= start else { return 0 }
        return ((end - start) / step) + 1
    }

    var totalGeneratedCount: Int {
        guard mode == .rangedSets else { return 0 }
        return countPerSet * max(repeatSets, 1)
    }

    func generatedValue(at index: Int) -> Int? {
        guard mode == .rangedSets else { return nil }
        let countPerSet = countPerSet
        guard countPerSet > 0, index >= 0, index < totalGeneratedCount else { return nil }
        let indexInSet = index % countPerSet
        return start + (indexInSet * step)
    }

    func formatted(_ value: Int) -> String {
        let digits = max(digits, 1)
        let raw = String(format: "%0\(digits)d", value)
        return prefix + raw + suffix
    }

    static let `default` = SerialSettings(
        mode: .rangedSets,
        start: 1,
        step: 1,
        end: 12,
        repeatSets: 1,
        digits: 1,
        prefix: "(",
        suffix: ")"
    )
}

struct DataTable: Codable, Equatable {
    var headers: [String]
    var rows: [[String: String]]
}

struct PrintAutomationSettings: Codable, Hashable {
    var enabled: Bool
    var wifiService: String
    var printerSSID: String
    var printerPassword: String
    var reconnectToPreviousWiFi: Bool
    var settleSeconds: Double
    /// Wi-Fi to return to after printing when the pre-print network couldn't
    /// be captured. macOS 15+ redacts the current SSID from every CLI without
    /// Location Services, so on those systems this (or the auto-detected
    /// preferred network) is the only way back. Optional: older documents
    /// decode without it.
    var restoreSSID: String?

    static let `default` = PrintAutomationSettings(
        enabled: false,
        wifiService: "Wi-Fi",
        printerSSID: "",
        printerPassword: "",
        reconnectToPreviousWiFi: true,
        settleSeconds: 2.0,
        restoreSSID: nil
    )

    var isConfigured: Bool {
        !printerSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// First-launch default. When the Mac's preferred-network list already
    /// contains a printer-looking SSID, the machine has joined that printer
    /// before — its password is in the keychain, so a passwordless join works
    /// (the restore path relies on the same fact). That makes it safe to ship
    /// with switching enabled out of the box.
    static func seededDefault(detectedPrinterSSID: String?) -> PrintAutomationSettings {
        var settings = PrintAutomationSettings.default
        if let ssid = detectedPrinterSSID?.trimmingCharacters(in: .whitespacesAndNewlines), !ssid.isEmpty {
            settings.printerSSID = ssid
            settings.enabled = true
        }
        return settings
    }

    /// Wi-Fi print setup is machine-local, not document content: a project
    /// file saved earlier (or on another Mac) must not revert this machine's
    /// printer SSID/password or the "Switch Wi-Fi on Print" checkbox when
    /// opened. The document's own settings only apply when this machine has
    /// nothing configured yet (e.g. a colleague's file seeding a new Mac).
    static func resolvedOnOpen(
        machineCached: PrintAutomationSettings,
        documentValue: PrintAutomationSettings
    ) -> PrintAutomationSettings {
        machineCached.isConfigured ? machineCached : documentValue
    }
}

struct PlacementSettings: Codable, Hashable {
    var selectedSlotIndices: [Int]
    var fillDirection: PlacementFillDirection

    static let `default` = PlacementSettings(selectedSlotIndices: [], fillDirection: .horizontal)
}

enum PlacementFillDirection: String, Codable, CaseIterable, Identifiable {
    case horizontal
    case vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal:
            return "Horizontal"
        case .vertical:
            return "Vertical"
        }
    }
}

struct MergeContext: Equatable {
    var row: [String: String]
    var serialValue: Int?
    var rowNumber: Int
    var pageNumber: Int
    var slotNumber: Int
    var isActive: Bool
}

/// RTF parsing is expensive and runs on every keystroke (`content.didSet`
/// re-checks the stored RTF) and once per slot in the sheet preview, so
/// identical payloads decode only once. Decoded values are immutable and
/// shared; copy before mutating.
enum RTFDecodeCache {
    private static let cache = NSCache<NSData, NSAttributedString>()

    static func decode(_ data: Data?) -> NSAttributedString? {
        guard let data else { return nil }
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    /// Pre-populates the cache when the attributed source of an RTF payload
    /// is already in hand (the inline editor encodes on every keystroke and
    /// the same payload is re-read within the same event cycle).
    static func seed(_ attributed: NSAttributedString, for data: Data) {
        cache.setObject(NSAttributedString(attributedString: attributed), forKey: data as NSData)
    }
}

struct LabelElement: Codable, Identifiable, Hashable {
    var id: UUID
    var type: ElementType
    var name: String
    var frame: RectMM
    var rotation: Double
    var opacity: Double
    var content: String {
        didSet {
            // The rich-text override is only valid while its plain string still
            // matches `content`. When `content` is edited by any surface other
            // than the inline editor (inspector "Content" box, token buttons,
            // quick presets, paste), those writes only touch `content`; without
            // this the stale RTF keeps shadowing the new text and the label
            // never updates. Drop the stale RTF so the edit actually renders.
            if richTextRTF != nil, LabelElement.plainText(fromRTF: richTextRTF) != content {
                richTextRTF = nil
            }
        }
    }
    var fontSize: Double
    var fontName: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var textAlignment: TextAlignModel
    var foreground: RGBAColor
    var background: RGBAColor
    var stroke: RGBAColor
    var strokeWidth: Double
    var cornerRadiusMM: Double
    var verticalTextLayout: Bool?
    /// When true, text uses the full element ellipse and each line follows the
    /// available chord instead of being restricted to an inscribed square.
    var usesCircularTextFlow: Bool?
    var richTextRTF: Data?
    var imageData: Data?
    var imageScaleMode: ImageScaleMode

    /// Decodes the plain string of an RTF payload, or nil if absent/undecodable.
    /// Used to decide whether a stored `richTextRTF` still matches `content`.
    static func plainText(fromRTF data: Data?) -> String? {
        RTFDecodeCache.decode(data)?.string
    }

    /// Converts every font run in an RTF payload to the given family while
    /// keeping each run's size and bold/italic traits. Used when the font is
    /// changed element-wide so text with per-selection styling follows along.
    static func rewritingFontFamily(of data: Data?, to family: String) -> Data? {
        guard
            let data,
            let attributed = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        else { return data }
        // Enumerate an immutable copy: mutating the string being enumerated
        // can re-visit ranges and apply the conversion twice.
        let source = NSAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: source.length)
        source.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let traits = NSFontManager.shared.traits(of: font)
            let converted = resolvedNSFont(
                name: family,
                size: font.pointSize,
                isBold: traits.contains(.boldFontMask),
                isItalic: traits.contains(.italicFontMask)
            )
            attributed.addAttribute(.font, value: converted, range: range)
        }
        return attributed.rtf(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) ?? data
    }

    /// Multiplies every font run's size in an RTF payload by `factor`,
    /// keeping families and traits. Used when the size is changed
    /// element-wide so per-selection sizes keep their relative ratios.
    static func scalingFontSizes(of data: Data?, by factor: Double) -> Data? {
        guard factor > 0, abs(factor - 1) > 0.0001 else { return data }
        guard let data, let decoded = RTFDecodeCache.decode(data) else { return data }
        let mutable = NSMutableAttributedString(attributedString: decoded)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // Enumerate the immutable original, not `mutable`: mutating the
        // string being enumerated can re-visit ranges and scale twice.
        decoded.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            guard let font = value as? NSFont else { return }
            mutable.addAttribute(.font, value: font.withSize(max(0.5, font.pointSize * factor)), range: range)
        }
        return mutable.rtf(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) ?? data
    }

    static func make(_ type: ElementType, index: Int) -> LabelElement {
        switch type {
        case .text:
            return LabelElement(
                id: UUID(),
                type: .text,
                name: "Text \(index)",
                frame: RectMM(x: 10, y: 8 + Double(index * 4), width: 76, height: 12),
                rotation: 0,
                opacity: 1,
                content: index == 1 ? "Product Label" : "Edit this text or use {{Column}}",
                fontSize: index == 1 ? 22 : 12,
                fontName: "Arial",
                isBold: index == 1,
                isItalic: false,
                isUnderline: false,
                textAlignment: .center,
                foreground: .black,
                background: .clear,
                stroke: .clear,
                strokeWidth: 0,
                cornerRadiusMM: 0,
                verticalTextLayout: false,
                usesCircularTextFlow: false,
                richTextRTF: nil,
                imageData: nil,
                imageScaleMode: .fit
            )
        case .rectangle:
            return LabelElement(
                id: UUID(),
                type: .rectangle,
                name: "Shape \(index)",
                frame: RectMM(x: 6, y: 6, width: 87, height: 45),
                rotation: 0,
                opacity: 1,
                content: "",
                fontSize: 12,
                fontName: "SF Pro",
                isBold: false,
                isItalic: false,
                isUnderline: false,
                textAlignment: .center,
                foreground: .clear,
                background: RGBAColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1),
                stroke: RGBAColor(red: 0.68, green: 0.74, blue: 0.91, alpha: 1),
                strokeWidth: 1,
                cornerRadiusMM: 2.5,
                verticalTextLayout: false,
                usesCircularTextFlow: false,
                richTextRTF: nil,
                imageData: nil,
                imageScaleMode: .fit
            )
        case .image:
            return LabelElement(
                id: UUID(),
                type: .image,
                name: "Image \(index)",
                frame: RectMM(x: 8, y: 8, width: 24, height: 24),
                rotation: 0,
                opacity: 1,
                content: "",
                fontSize: 12,
                fontName: "SF Pro",
                isBold: false,
                isItalic: false,
                isUnderline: false,
                textAlignment: .center,
                foreground: .black,
                background: .softGray,
                stroke: RGBAColor(red: 0.78, green: 0.8, blue: 0.84, alpha: 1),
                strokeWidth: 1,
                cornerRadiusMM: 2,
                verticalTextLayout: false,
                usesCircularTextFlow: false,
                richTextRTF: nil,
                imageData: nil,
                imageScaleMode: .fit
            )
        case .qrCode:
            return LabelElement(
                id: UUID(),
                type: .qrCode,
                name: "QR \(index)",
                frame: RectMM(x: 68, y: 8, width: 22, height: 22),
                rotation: 0,
                opacity: 1,
                content: "https://label.kr",
                fontSize: 12,
                fontName: "SF Pro",
                isBold: false,
                isItalic: false,
                isUnderline: false,
                textAlignment: .center,
                foreground: .black,
                background: .white,
                stroke: RGBAColor(red: 0.75, green: 0.77, blue: 0.82, alpha: 1),
                strokeWidth: 1,
                cornerRadiusMM: 1.2,
                verticalTextLayout: false,
                usesCircularTextFlow: false,
                richTextRTF: nil,
                imageData: nil,
                imageScaleMode: .fit
            )
        case .code128:
            return LabelElement(
                id: UUID(),
                type: .code128,
                name: "Barcode \(index)",
                frame: RectMM(x: 10, y: 33, width: 80, height: 14),
                rotation: 0,
                opacity: 1,
                content: "SKU-0001",
                fontSize: 11,
                fontName: "SF Pro",
                isBold: false,
                isItalic: false,
                isUnderline: false,
                textAlignment: .center,
                foreground: .black,
                background: .white,
                stroke: RGBAColor(red: 0.75, green: 0.77, blue: 0.82, alpha: 1),
                strokeWidth: 1,
                cornerRadiusMM: 1.2,
                verticalTextLayout: false,
                usesCircularTextFlow: false,
                richTextRTF: nil,
                imageData: nil,
                imageScaleMode: .fit
            )
        }
    }
}

struct EmbeddedFont: Codable, Hashable {
    var postScriptName: String
    var familyName: String
    var data: Data
}

struct PrintBatch: Codable, Equatable, Identifiable {
    /// Keeps accidental or malformed projects from requesting effectively
    /// unbounded PDF generation. The capture UI rejects over-limit setups
    /// explicitly instead of silently dropping labels.
    static let quantityRange = 1...100_000

    var id: UUID
    var name: String
    var elements: [LabelElement]
    /// Numbering and CSV inputs are captured with the label so a queue entry
    /// behaves like a snapshot of the setup, not just a copy of its artwork.
    /// Optional fields keep print queues written by the first queue release
    /// backward compatible.
    var serialSettings: SerialSettings?
    var dataTable: DataTable?
    /// Physical sheet placement captured with this setup. When present, later
    /// changes to the editor's start position cannot move this batch.
    var capturedPlacement: PlacementSettings?
    var startPageIndex: Int?
    /// Offset within the captured placement's first page. New captures start
    /// at zero; this preserves the exact continuation point of legacy queues
    /// when they are upgraded from one global stream to fixed batches.
    var startSlotOffset: Int?
    /// Global merge index used by legacy queues before each batch gained its
    /// own Numbering/CSV snapshot.
    var legacySequenceOffset: Int?
    private var storedQuantity: Int

    var quantity: Int {
        get { storedQuantity }
        set { storedQuantity = Self.normalizedQuantity(newValue) }
    }

    init(
        id: UUID = UUID(),
        name: String,
        quantity: Int,
        elements: [LabelElement],
        serialSettings: SerialSettings? = nil,
        dataTable: DataTable? = nil,
        capturedPlacement: PlacementSettings? = nil,
        startPageIndex: Int? = nil,
        startSlotOffset: Int? = nil,
        legacySequenceOffset: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.elements = elements
        self.serialSettings = serialSettings
        self.dataTable = dataTable
        self.capturedPlacement = capturedPlacement
        self.startPageIndex = startPageIndex.map { max(0, $0) }
        self.startSlotOffset = startSlotOffset.map { max(0, $0) }
        self.legacySequenceOffset = legacySequenceOffset.map { max(0, $0) }
        self.storedQuantity = Self.normalizedQuantity(quantity)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case quantity
        case elements
        case serialSettings
        case dataTable
        case capturedPlacement
        case startPageIndex
        case startSlotOffset
        case legacySequenceOffset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        elements = try container.decode([LabelElement].self, forKey: .elements)
        serialSettings = try container.decodeIfPresent(SerialSettings.self, forKey: .serialSettings)
        dataTable = try container.decodeIfPresent(DataTable.self, forKey: .dataTable)
        capturedPlacement = try container.decodeIfPresent(PlacementSettings.self, forKey: .capturedPlacement)
        startPageIndex = try container.decodeIfPresent(Int.self, forKey: .startPageIndex)
            .map { max(0, $0) }
        startSlotOffset = try container.decodeIfPresent(Int.self, forKey: .startSlotOffset)
            .map { max(0, $0) }
        legacySequenceOffset = try container.decodeIfPresent(Int.self, forKey: .legacySequenceOffset)
            .map { max(0, $0) }
        storedQuantity = Self.normalizedQuantity(
            try container.decode(Int.self, forKey: .quantity)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(elements, forKey: .elements)
        try container.encodeIfPresent(serialSettings, forKey: .serialSettings)
        try container.encodeIfPresent(dataTable, forKey: .dataTable)
        try container.encodeIfPresent(capturedPlacement, forKey: .capturedPlacement)
        try container.encodeIfPresent(startPageIndex, forKey: .startPageIndex)
        try container.encodeIfPresent(startSlotOffset, forKey: .startSlotOffset)
        try container.encodeIfPresent(legacySequenceOffset, forKey: .legacySequenceOffset)
    }

    private static func normalizedQuantity(_ quantity: Int) -> Int {
        min(
            max(quantityRange.lowerBound, quantity),
            quantityRange.upperBound
        )
    }
}

struct SlotRenderPayload: Equatable {
    var elements: [LabelElement]
    var context: MergeContext
    var serialSettings: SerialSettings
    var batchID: UUID?

    init(
        elements: [LabelElement],
        context: MergeContext,
        serialSettings: SerialSettings = .default,
        batchID: UUID? = nil
    ) {
        self.elements = elements
        self.context = context
        self.serialSettings = serialSettings
        self.batchID = batchID
    }
}

struct PrintPlacementConflict: Equatable {
    var existingBatchName: String
    var pageIndex: Int
    var slotIndex: Int
}

/// Placement for the not-yet-captured setup shown only in the interactive
/// preview. It must never participate in PDF/PNG/print rendering.
struct DraftPlacementPlan: Equatable {
    var placement: PlacementSettings
    var startPageIndex: Int
    var quantity: Int

    init(
        placement: PlacementSettings,
        startPageIndex: Int,
        quantity: Int
    ) {
        self.placement = placement
        self.startPageIndex = max(0, startPageIndex)
        self.quantity = max(1, quantity)
    }
}

enum InteractiveSlotRenderSource: Equatable {
    case captured(UUID)
    case draft
    case inactive
}

struct InteractiveSlotRenderPayload: Equatable {
    var payload: SlotRenderPayload
    var source: InteractiveSlotRenderSource
}

struct LabelDocument: Codable, Equatable {
    var title: String
    var sheet: SheetTemplate
    var elements: [LabelElement]
    var serial: SerialSettings
    var dataTable: DataTable?
    var notes: String
    var formatCode: String?
    var formatFamily: ProductFamily?
    var formatSourceURL: String?
    var formatPDFTemplateURL: String?
    var printAutomation: PrintAutomationSettings
    var placement: PlacementSettings
    /// Font files bundled into the project so custom (non-system) fonts render
    /// identically on machines that don't have them installed. Populated at save
    /// time, registered (process scope) at load time, then cleared from memory.
    var embeddedFonts: [EmbeddedFont]? = nil
    /// Snapshots queued for a later multi-design print. Optional so projects
    /// written before print queues existed continue to decode unchanged.
    var printQueue: [PrintBatch]? = nil

    var printBatches: [PrintBatch] {
        get { printQueue ?? [] }
        set { printQueue = newValue.isEmpty ? nil : newValue }
    }

    var queuedLabelCount: Int {
        printBatches.reduce(into: 0) { count, batch in
            let (sum, overflow) = count.addingReportingOverflow(batch.quantity)
            count = overflow ? Int.max : sum
        }
    }

    var hasQueuedLabels: Bool {
        queuedLabelCount > 0
    }

    var totalSlotCount: Int {
        max(1, sheet.columns * sheet.rows)
    }

    var activeSlotIndices: [Int] {
        orderedSlotIndices(for: placement)
    }

    func orderedSlotIndices(for placement: PlacementSettings) -> [Int] {
        let indices = placement.selectedSlotIndices
            .filter { $0 >= 0 && $0 < totalSlotCount }
        let normalized = indices.isEmpty ? Array(0..<totalSlotCount) : Array(Set(indices))
        switch placement.fillDirection {
        case .horizontal:
            return normalized.sorted()
        case .vertical:
            return normalized.sorted { lhs, rhs in
                let leftColumn = lhs % sheet.columns
                let rightColumn = rhs % sheet.columns
                if leftColumn == rightColumn {
                    return lhs / sheet.columns < rhs / sheet.columns
                }
                return leftColumn < rightColumn
            }
        }
    }

    func slotIndicesStarting(
        at slotIndex: Int,
        fillDirection: PlacementFillDirection
    ) -> [Int] {
        let allSlots = orderedSlotIndices(
            for: PlacementSettings(
                selectedSlotIndices: [],
                fillDirection: fillDirection
            )
        )
        guard let start = allSlots.firstIndex(of: slotIndex) else { return [] }
        return Array(allSlots[start...])
    }

    var pageCapacity: Int {
        max(1, activeSlotIndices.count)
    }

    /// Label count produced by the setup currently visible in Numbering/CSV,
    /// deliberately ignoring any already-captured print queue.
    var currentSetupLabelCount: Int {
        if let dataTable, !dataTable.rows.isEmpty {
            return dataTable.rows.count
        }
        if serial.mode == .rangedSets, serial.totalGeneratedCount > 0 {
            return serial.totalGeneratedCount
        }
        return pageCapacity
    }

    var mergeRowCount: Int {
        if hasQueuedLabels {
            return queuedLabelCount
        }
        return currentSetupLabelCount
    }

    var hasFiniteMergeRows: Bool {
        mergeRowCount > 0
    }

    var pageCount: Int {
        guard hasQueuedLabels else {
            let mergeRowCount = mergeRowCount
            guard mergeRowCount > 0 else { return 1 }
            return max(1, pagesNeeded(quantity: mergeRowCount, capacity: pageCapacity))
        }

        var maximumPageCount = 0
        var legacyQuantity = 0
        for batch in printBatches {
            guard let capturedPlacement = batch.capturedPlacement else {
                let (sum, overflow) = legacyQuantity.addingReportingOverflow(batch.quantity)
                legacyQuantity = overflow ? Int.max : sum
                continue
            }

            let capacity = max(1, orderedSlotIndices(for: capturedPlacement).count)
            let span = pagesNeeded(
                quantity: batch.quantity,
                capacity: capacity,
                startOffset: batch.startSlotOffset ?? 0
            )
            let startPage = max(0, batch.startPageIndex ?? 0)
            let (endPage, overflow) = startPage.addingReportingOverflow(span)
            maximumPageCount = max(maximumPageCount, overflow ? Int.max : endPage)
        }

        if legacyQuantity > 0 {
            maximumPageCount = max(
                maximumPageCount,
                pagesNeeded(quantity: legacyQuantity, capacity: pageCapacity)
            )
        }
        return max(1, maximumPageCount)
    }

    func visiblePreviewSlotIndices(pageIndex: Int) -> [Int] {
        if !hasFiniteMergeRows {
            return activeSlotIndices
        }

        let candidateSlots = printBatches.contains { $0.capturedPlacement != nil }
            ? Array(0..<totalSlotCount)
            : activeSlotIndices
        let visible = candidateSlots.filter { slotIndex in
            mergeContext(slotIndex: slotIndex, pageIndex: pageIndex).isActive
        }
        if hasQueuedLabels {
            return visible
        }
        return visible.isEmpty ? Array(activeSlotIndices.prefix(1)) : visible
    }

    private func pagesNeeded(
        quantity: Int,
        capacity: Int,
        startOffset: Int = 0
    ) -> Int {
        let normalizedQuantity = max(1, quantity)
        let normalizedCapacity = max(1, capacity)
        let normalizedOffset = min(
            max(0, startOffset),
            normalizedCapacity - 1
        )
        let (adjustedQuantity, overflow) = normalizedQuantity
            .addingReportingOverflow(normalizedOffset)
        guard !overflow else { return Int.max }
        return ((adjustedQuantity - 1) / normalizedCapacity) + 1
    }

    func bounds(for slotIndices: [Int]) -> RectMM {
        let indices = slotIndices.isEmpty ? activeSlotIndices : slotIndices
        guard let first = indices.first else {
            return RectMM(x: 0, y: 0, width: sheet.pageWidthMM, height: sheet.pageHeightMM)
        }

        let firstRow = first / sheet.columns
        let firstColumn = first % sheet.columns
        let firstFrame = sheet.slotFrame(column: firstColumn, row: firstRow)

        var minX = firstFrame.x
        var minY = firstFrame.y
        var maxX = firstFrame.x + firstFrame.width
        var maxY = firstFrame.y + firstFrame.height

        for index in indices.dropFirst() {
            let row = index / sheet.columns
            let column = index % sheet.columns
            let frame = sheet.slotFrame(column: column, row: row)
            minX = min(minX, frame.x)
            minY = min(minY, frame.y)
            maxX = max(maxX, frame.x + frame.width)
            maxY = max(maxY, frame.y + frame.height)
        }

        return RectMM(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func coordinate(for slotIndex: Int) -> (row: Int, column: Int) {
        let row = (slotIndex / sheet.columns) + 1
        let column = (slotIndex % sheet.columns) + 1
        return (row, column)
    }

    func coordinateLabel(for slotIndex: Int) -> String {
        let coordinate = coordinate(for: slotIndex)
        return "(\(coordinate.row),\(coordinate.column))"
    }

    func mergeContext(slotIndex: Int, pageIndex: Int) -> MergeContext {
        if hasQueuedLabels {
            guard let position = queuedBatchPosition(
                slotIndex: slotIndex,
                pageIndex: pageIndex
            ) else {
                return inactiveMergeContext(
                    slotIndex: slotIndex,
                    pageIndex: pageIndex
                )
            }

            let batchSerial = position.batch.serialSettings ?? serial
            let sequenceIndex = position.batch.serialSettings == nil
                ? position.sequenceIndex
                : position.localIndex
            let tableRows: [[String: String]]
            if position.batch.serialSettings != nil {
                tableRows = position.batch.dataTable?.rows ?? []
            } else {
                // Compatibility for queues created before setup snapshots were
                // added: their merge inputs remain document-global.
                tableRows = dataTable?.rows ?? []
            }

            let rowData: [String: String]
            let serialValue: Int?
            if !tableRows.isEmpty {
                rowData = sequenceIndex < tableRows.count
                    ? tableRows[sequenceIndex]
                    : [:]
                serialValue = batchSerial.start + (sequenceIndex * batchSerial.step)
            } else if batchSerial.mode == .rangedSets {
                let generated = batchSerial.generatedValue(at: sequenceIndex)
                    ?? (batchSerial.start + (sequenceIndex * batchSerial.step))
                serialValue = generated
                let countPerSet = max(batchSerial.countPerSet, 1)
                rowData = [
                    "serial": batchSerial.formatted(generated),
                    "serial_raw": "\(generated)",
                    "set": "\((sequenceIndex / countPerSet) + 1)",
                    "index_in_set": "\((sequenceIndex % countPerSet) + 1)"
                ]
            } else {
                rowData = [:]
                serialValue = batchSerial.start + (sequenceIndex * batchSerial.step)
            }

            return MergeContext(
                row: rowData,
                serialValue: serialValue,
                rowNumber: sequenceIndex + 1,
                pageNumber: pageIndex + 1,
                slotNumber: slotIndex + 1,
                isActive: true
            )
        }

        guard let globalIndex = globalIndex(
            slotIndex: slotIndex,
            pageIndex: pageIndex
        ) else {
            return inactiveMergeContext(
                slotIndex: slotIndex,
                pageIndex: pageIndex
            )
        }

        let isActive: Bool
        let rowData: [String: String]
        let serialValue: Int?
        let rowNumber: Int

        if let dataTable, !dataTable.rows.isEmpty {
            let tableRows = dataTable.rows
            isActive = globalIndex < tableRows.count
            rowData = isActive ? tableRows[globalIndex] : [:]
            serialValue = isActive ? (serial.start + (globalIndex * serial.step)) : nil
            rowNumber = globalIndex + 1
        } else if serial.mode == .rangedSets {
            serialValue = serial.generatedValue(at: globalIndex)
            isActive = serialValue != nil
            rowNumber = globalIndex + 1
            if let serialValue {
                let countPerSet = max(serial.countPerSet, 1)
                let setNumber = (globalIndex / countPerSet) + 1
                let indexInSet = (globalIndex % countPerSet) + 1
                rowData = [
                    "serial": serial.formatted(serialValue),
                    "serial_raw": "\(serialValue)",
                    "set": "\(setNumber)",
                    "index_in_set": "\(indexInSet)"
                ]
            } else {
                rowData = [:]
            }
        } else {
            isActive = true
            rowData = [:]
            serialValue = serial.start + (globalIndex * serial.step)
            rowNumber = globalIndex + 1
        }

        return MergeContext(
            row: rowData,
            serialValue: serialValue,
            rowNumber: rowNumber,
            pageNumber: pageIndex + 1,
            slotNumber: slotIndex + 1,
            isActive: isActive
        )
    }

    /// Merge values for the setup currently being edited. Captured batches
    /// deliberately do not participate, so changing Numbering/CSV after a
    /// capture is reflected immediately on the label editor.
    func currentSetupMergeContext(slotIndex: Int, pageIndex: Int) -> MergeContext {
        var currentSetup = self
        currentSetup.printQueue = nil
        return currentSetup.mergeContext(slotIndex: slotIndex, pageIndex: pageIndex)
    }

    func draftPlacementPlan(startPageIndex: Int) -> DraftPlacementPlan {
        DraftPlacementPlan(
            placement: placement,
            startPageIndex: startPageIndex,
            quantity: currentSetupLabelCount
        )
    }

    /// Slots occupied by the current, not-yet-captured setup on one physical
    /// page. The setup sequence always starts at local index zero even when it
    /// is staged on page two or later.
    func draftPreviewSlotIndices(
        pageIndex: Int,
        plan: DraftPlacementPlan
    ) -> [Int] {
        let schedule = placementSchedule(for: plan)
        return usedSlots(in: schedule, pageIndex: pageIndex)
    }

    /// Preview-only payload for the current setup. Captured output continues
    /// to use `renderPayload`, so an uncommitted draft can never leak into an
    /// exported or printed page.
    func draftPreviewPayload(
        slotIndex: Int,
        pageIndex: Int,
        plan: DraftPlacementPlan
    ) -> SlotRenderPayload {
        let schedule = placementSchedule(for: plan)
        guard localIndex(
            in: schedule,
            slotIndex: slotIndex,
            pageIndex: pageIndex
        ) != nil else {
            return SlotRenderPayload(
                elements: elements,
                context: inactiveMergeContext(
                    slotIndex: slotIndex,
                    pageIndex: pageIndex
                ),
                serialSettings: serial
            )
        }

        var currentSetup = self
        currentSetup.printQueue = nil
        currentSetup.placement = plan.placement
        let relativePageIndex = pageIndex - plan.startPageIndex
        var payload = currentSetup.renderPayload(
            slotIndex: slotIndex,
            pageIndex: relativePageIndex
        )
        // Sequence data is local to the draft, but {{page}} must reflect the
        // physical sheet page on which the draft will be captured.
        payload.context.pageNumber = pageIndex + 1
        return payload
    }

    /// Composes the interactive preview without changing committed rendering.
    /// A captured slot always wins; callers pass only a conflict-free plan.
    func interactivePreviewPayload(
        slotIndex: Int,
        pageIndex: Int,
        validDraftPlan: DraftPlacementPlan?
    ) -> InteractiveSlotRenderPayload {
        let committed = renderPayload(
            slotIndex: slotIndex,
            pageIndex: pageIndex
        )
        if committed.context.isActive, let batchID = committed.batchID {
            return InteractiveSlotRenderPayload(
                payload: committed,
                source: .captured(batchID)
            )
        }

        if let validDraftPlan {
            let draft = draftPreviewPayload(
                slotIndex: slotIndex,
                pageIndex: pageIndex,
                plan: validDraftPlan
            )
            if draft.context.isActive {
                return InteractiveSlotRenderPayload(
                    payload: draft,
                    source: .draft
                )
            }
        }

        return InteractiveSlotRenderPayload(
            payload: committed,
            source: .inactive
        )
    }

    func draftConflictSlotIndices(
        pageIndex: Int,
        plan: DraftPlacementPlan
    ) -> [Int] {
        draftPreviewSlotIndices(pageIndex: pageIndex, plan: plan).filter {
            let committed = renderPayload(slotIndex: $0, pageIndex: pageIndex)
            return committed.context.isActive && committed.batchID != nil
        }
    }

    func queuedBatch(atGlobalIndex globalIndex: Int) -> PrintBatch? {
        flattenedQueuedBatchPosition(atGlobalIndex: globalIndex)?.batch
    }

    private func flattenedQueuedBatchPosition(
        atGlobalIndex globalIndex: Int
    ) -> (batch: PrintBatch, localIndex: Int)? {
        guard globalIndex >= 0 else { return nil }

        var remainingIndex = globalIndex
        for batch in printBatches {
            let quantity = max(0, batch.quantity)
            if remainingIndex < quantity {
                return (batch, remainingIndex)
            }
            remainingIndex -= quantity
        }
        return nil
    }

    func renderPayload(slotIndex: Int, pageIndex: Int) -> SlotRenderPayload {
        let context = mergeContext(slotIndex: slotIndex, pageIndex: pageIndex)
        guard
            hasQueuedLabels,
            context.isActive,
            let position = queuedBatchPosition(
                slotIndex: slotIndex,
                pageIndex: pageIndex
            )
        else {
            return SlotRenderPayload(
                elements: elements,
                context: context,
                serialSettings: serial
            )
        }

        return SlotRenderPayload(
            elements: position.batch.elements,
            context: context,
            serialSettings: position.batch.serialSettings ?? serial,
            batchID: position.batch.id
        )
    }

    /// Upgrades queues written before placement snapshots existed. Their old
    /// behavior was one continuous stream through the document's current
    /// placement; page + slot offsets reproduce that exact visible mapping,
    /// then make every batch immutable for future placement changes.
    mutating func freezeLegacyPrintQueuePlacement() {
        guard var batches = printQueue,
              batches.contains(where: { $0.capturedPlacement == nil })
        else { return }

        let frozenPlacement = placement
        let capacity = max(1, orderedSlotIndices(for: frozenPlacement).count)
        var legacyOffset = 0
        for index in batches.indices where batches[index].capturedPlacement == nil {
            batches[index].capturedPlacement = frozenPlacement
            batches[index].startPageIndex = legacyOffset / capacity
            batches[index].startSlotOffset = legacyOffset % capacity
            batches[index].legacySequenceOffset = legacyOffset
            let (nextOffset, overflow) = legacyOffset
                .addingReportingOverflow(batches[index].quantity)
            legacyOffset = overflow ? Int.max : nextOffset
        }
        printQueue = batches
    }

    func firstPlacementConflict(
        for candidate: PrintBatch
    ) -> PrintPlacementConflict? {
        guard let candidateSchedule = placementSchedule(for: candidate) else {
            return nil
        }
        return firstPlacementConflict(for: candidateSchedule)
    }

    func firstPlacementConflict(
        for plan: DraftPlacementPlan
    ) -> PrintPlacementConflict? {
        firstPlacementConflict(for: placementSchedule(for: plan))
    }

    private func firstPlacementConflict(
        for candidateSchedule: PlacementSchedule
    ) -> PrintPlacementConflict? {
        for existing in printBatches {
            guard let existingSchedule = placementSchedule(for: existing),
                  let collision = firstCollision(
                    candidateSchedule,
                    existingSchedule
                  )
            else { continue }
            return PrintPlacementConflict(
                existingBatchName: existing.name,
                pageIndex: collision.pageIndex,
                slotIndex: collision.slotIndex
            )
        }

        let legacyBatches = printBatches.filter { $0.capturedPlacement == nil }
        let legacyQuantity = legacyBatches.reduce(into: 0) { total, batch in
            let (sum, overflow) = total.addingReportingOverflow(batch.quantity)
            total = overflow ? Int.max : sum
        }
        if legacyQuantity > 0 {
            let legacySchedule = PlacementSchedule(
                placement: placement,
                startPageIndex: 0,
                startSlotOffset: 0,
                quantity: legacyQuantity,
                name: legacyBatches.first?.name ?? "Existing capture"
            )
            if let collision = firstCollision(candidateSchedule, legacySchedule) {
                return PrintPlacementConflict(
                    existingBatchName: legacySchedule.name,
                    pageIndex: collision.pageIndex,
                    slotIndex: collision.slotIndex
                )
            }
        }
        return nil
    }

    func capturedStartPosition(
        for batch: PrintBatch
    ) -> (pageIndex: Int, slotIndex: Int)? {
        guard let schedule = placementSchedule(for: batch),
              let slotIndex = usedSlots(
                in: schedule,
                pageIndex: schedule.startPageIndex
              ).first
        else { return nil }
        return (schedule.startPageIndex, slotIndex)
    }

    private struct QueueSlotPosition {
        var batch: PrintBatch
        var localIndex: Int
        var sequenceIndex: Int
    }

    private struct PlacementSchedule {
        var placement: PlacementSettings
        var startPageIndex: Int
        var startSlotOffset: Int
        var quantity: Int
        var name: String
    }

    private func queuedBatchPosition(
        slotIndex: Int,
        pageIndex: Int
    ) -> QueueSlotPosition? {
        guard pageIndex >= 0, slotIndex >= 0, slotIndex < totalSlotCount else {
            return nil
        }

        let legacyGlobalIndex = globalIndex(
            slotIndex: slotIndex,
            pageIndex: pageIndex
        )
        var remainingLegacyIndex = legacyGlobalIndex

        for batch in printBatches {
            if let capturedPlacement = batch.capturedPlacement {
                let schedule = PlacementSchedule(
                    placement: capturedPlacement,
                    startPageIndex: max(0, batch.startPageIndex ?? 0),
                    startSlotOffset: max(0, batch.startSlotOffset ?? 0),
                    quantity: batch.quantity,
                    name: batch.name
                )
                if let localIndex = localIndex(
                    in: schedule,
                    slotIndex: slotIndex,
                    pageIndex: pageIndex
                ) {
                    let sequenceOffset = max(
                        0,
                        batch.legacySequenceOffset ?? 0
                    )
                    let (sequenceIndex, overflow) = sequenceOffset
                        .addingReportingOverflow(localIndex)
                    return QueueSlotPosition(
                        batch: batch,
                        localIndex: localIndex,
                        sequenceIndex: overflow ? Int.max : sequenceIndex
                    )
                }
                continue
            }

            guard let legacyIndex = remainingLegacyIndex else { continue }
            if legacyIndex < batch.quantity {
                return QueueSlotPosition(
                    batch: batch,
                    localIndex: legacyIndex,
                    sequenceIndex: legacyGlobalIndex ?? legacyIndex
                )
            }
            remainingLegacyIndex = legacyIndex - batch.quantity
        }
        return nil
    }

    private func placementSchedule(for batch: PrintBatch) -> PlacementSchedule? {
        guard let capturedPlacement = batch.capturedPlacement else { return nil }
        return PlacementSchedule(
            placement: capturedPlacement,
            startPageIndex: max(0, batch.startPageIndex ?? 0),
            startSlotOffset: max(0, batch.startSlotOffset ?? 0),
            quantity: batch.quantity,
            name: batch.name
        )
    }

    private func placementSchedule(
        for plan: DraftPlacementPlan
    ) -> PlacementSchedule {
        PlacementSchedule(
            placement: plan.placement,
            startPageIndex: plan.startPageIndex,
            startSlotOffset: 0,
            quantity: plan.quantity,
            name: "Current setup"
        )
    }

    private func localIndex(
        in schedule: PlacementSchedule,
        slotIndex: Int,
        pageIndex: Int
    ) -> Int? {
        let relativePage = pageIndex - schedule.startPageIndex
        guard relativePage >= 0 else { return nil }
        let slots = orderedSlotIndices(for: schedule.placement)
        guard let indexOnPage = slots.firstIndex(of: slotIndex) else { return nil }
        let (pageOffset, multiplicationOverflow) = relativePage
            .multipliedReportingOverflow(by: slots.count)
        guard !multiplicationOverflow else { return nil }
        let (index, additionOverflow) = pageOffset
            .addingReportingOverflow(indexOnPage)
        let normalizedStartOffset = min(
            schedule.startSlotOffset,
            max(0, slots.count - 1)
        )
        guard
            !additionOverflow,
            index >= normalizedStartOffset
        else { return nil }
        let localIndex = index - normalizedStartOffset
        guard localIndex < schedule.quantity else { return nil }
        return localIndex
    }

    private func usedSlots(
        in schedule: PlacementSchedule,
        pageIndex: Int
    ) -> [Int] {
        let slots = orderedSlotIndices(for: schedule.placement)
        return slots.filter {
            localIndex(
                in: schedule,
                slotIndex: $0,
                pageIndex: pageIndex
            ) != nil
        }
    }

    private func firstCollision(
        _ lhs: PlacementSchedule,
        _ rhs: PlacementSchedule
    ) -> (pageIndex: Int, slotIndex: Int)? {
        let lhsSpan = pagesNeeded(
            quantity: lhs.quantity,
            capacity: orderedSlotIndices(for: lhs.placement).count,
            startOffset: lhs.startSlotOffset
        )
        let rhsSpan = pagesNeeded(
            quantity: rhs.quantity,
            capacity: orderedSlotIndices(for: rhs.placement).count,
            startOffset: rhs.startSlotOffset
        )
        let (lhsEnd, lhsOverflow) = lhs.startPageIndex
            .addingReportingOverflow(lhsSpan)
        let (rhsEnd, rhsOverflow) = rhs.startPageIndex
            .addingReportingOverflow(rhsSpan)
        let overlapStart = max(lhs.startPageIndex, rhs.startPageIndex)
        let overlapEnd = min(
            lhsOverflow ? Int.max : lhsEnd,
            rhsOverflow ? Int.max : rhsEnd
        )
        guard overlapStart < overlapEnd else { return nil }

        var pagesToCheck = [overlapStart, overlapEnd - 1]
        if overlapEnd - overlapStart > 2 {
            pagesToCheck.append(overlapStart + 1)
        }
        for pageIndex in Set(pagesToCheck).sorted() {
            let left = Set(usedSlots(in: lhs, pageIndex: pageIndex))
            let right = Set(usedSlots(in: rhs, pageIndex: pageIndex))
            if let slotIndex = left.intersection(right).min() {
                return (pageIndex, slotIndex)
            }
        }
        return nil
    }

    private func inactiveMergeContext(
        slotIndex: Int,
        pageIndex: Int
    ) -> MergeContext {
        MergeContext(
            row: [:],
            serialValue: nil,
            rowNumber: 0,
            pageNumber: max(0, pageIndex) + 1,
            slotNumber: max(0, slotIndex) + 1,
            isActive: false
        )
    }

    private func globalIndex(slotIndex: Int, pageIndex: Int) -> Int? {
        guard
            pageIndex >= 0,
            let logicalSlot = activeSlotIndices.firstIndex(of: slotIndex)
        else {
            return nil
        }
        let (pageOffset, multiplicationOverflow) = pageIndex
            .multipliedReportingOverflow(by: pageCapacity)
        guard !multiplicationOverflow else { return nil }
        let (index, additionOverflow) = pageOffset
            .addingReportingOverflow(logicalSlot)
        return additionOverflow ? nil : index
    }

    mutating func clampElementsToSheet() {
        func clamped(_ elements: [LabelElement]) -> [LabelElement] {
            elements.map { element in
                var copy = element
                if sheet.shape == .circle,
                   element.type == .text,
                   element.usesCircularTextFlow == true {
                    copy.frame = RectMM(
                        x: 0,
                        y: 0,
                        width: sheet.labelWidthMM,
                        height: sheet.labelHeightMM
                    )
                } else {
                    copy.frame = element.frame.clamped(
                        maxWidth: sheet.labelWidthMM,
                        maxHeight: sheet.labelHeightMM
                    )
                }
                return copy
            }
        }

        elements = clamped(elements)
        if let printQueue {
            self.printQueue = printQueue.map { batch in
                var copy = batch
                copy.elements = clamped(batch.elements)
                return copy
            }
        }
    }

    static let starter = LabelDocument(
        title: "iLabel2Mac Demo",
        sheet: SheetTemplate.presets[0],
        elements: [
            .make(.rectangle, index: 1),
            .make(.text, index: 1),
            .make(.text, index: 2),
            .make(.qrCode, index: 1),
            .make(.code128, index: 1)
        ],
        serial: .default,
        dataTable: nil,
        notes: "Use {{Column}}, {{serial}}, {{page}}, {{slot}}, {{row}}, {{date}} placeholders.",
        formatCode: nil,
        formatFamily: nil,
        formatSourceURL: nil,
        formatPDFTemplateURL: nil,
        printAutomation: .default,
        placement: .default
    )
}
