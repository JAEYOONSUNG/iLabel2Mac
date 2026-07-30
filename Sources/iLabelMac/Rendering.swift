import SwiftUI
import AppKit
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import CoreText

private let printRasterDPI: CGFloat = 720

enum MergeRenderer {
    static func resolve(_ template: String, context: MergeContext, serialSettings: SerialSettings) -> String {
        let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return template
        }

        let matches = regex.matches(
            in: template,
            options: [],
            range: NSRange(location: 0, length: (template as NSString).length)
        )
        let loweredRow = Dictionary(uniqueKeysWithValues: context.row.map { ($0.key.lowercased(), $0.value) })
        var output = template

        for match in matches.reversed() {
            guard
                let tokenRange = Range(match.range(at: 1), in: output),
                let fullRange = Range(match.range, in: output)
            else {
                continue
            }

            let token = String(output[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = value(for: token, context: context, row: loweredRow, serialSettings: serialSettings)
            output.replaceSubrange(fullRange, with: replacement)
        }

        return output
    }

    private static func value(
        for token: String,
        context: MergeContext,
        row: [String: String],
        serialSettings: SerialSettings
    ) -> String {
        let lowered = token.lowercased()
        switch lowered {
        case "serial":
            guard let serialValue = context.serialValue else { return "" }
            return serialSettings.formatted(serialValue)
        case "serial_raw":
            guard let serialValue = context.serialValue else { return "" }
            return "\(serialValue)"
        case "row":
            guard context.isActive else { return "" }
            return "\(context.rowNumber)"
        case "page":
            return "\(context.pageNumber)"
        case "slot":
            return "\(context.slotNumber)"
        case "date":
            return DateFormatter.shortISO.string(from: .now)
        case "time":
            return DateFormatter.timeOnly.string(from: .now)
        default:
            return row[lowered] ?? ""
        }
    }
}

enum TextLayoutRenderer {
    static func displayString(
        for element: LabelElement,
        context: MergeContext,
        serialSettings: SerialSettings
    ) -> String {
        let resolved = MergeRenderer.resolve(element.content, context: context, serialSettings: serialSettings)
        guard element.verticalTextLayout == true else { return resolved }
        return verticalize(resolved)
    }

    private static func verticalize(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        return lines.map { line in
            Array(line).map(String.init).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func attributedString(
        for element: LabelElement,
        context: MergeContext,
        serialSettings: SerialSettings
    ) -> NSAttributedString {
        let base: NSMutableAttributedString
        if let attributed = RTFDecodeCache.decode(element.richTextRTF),
           attributed.string == element.content {
            // Only honor the rich-text override while it still matches `content`.
            // Guards against older documents saved before content/RTF were kept
            // in sync, so a diverged `content` edit still renders.
            base = normalizedRichText(attributed, for: element)
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = element.textAlignment.nsTextAlignment
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PageRenderer.nsFont(name: element.fontName, size: CGFloat(element.fontSize), isBold: element.isBold, isItalic: element.isItalic),
                .foregroundColor: element.foreground.nsColor,
                .paragraphStyle: paragraph,
                .underlineStyle: element.isUnderline ? NSUnderlineStyle.single.rawValue : 0
            ]
            let text = displayString(for: element, context: context, serialSettings: serialSettings)
            return trimmingTrailingLineBreaks(
                from: NSAttributedString(string: text, attributes: attributes)
            )
        }

        let pattern = #"\{\{\s*([^}]+?)\s*\}\}"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let matches = regex?.matches(in: base.string, options: [], range: NSRange(location: 0, length: (base.string as NSString).length)) ?? []
        for match in matches.reversed() {
            let tokenRange = match.range
            let tokenText = (base.string as NSString).substring(with: tokenRange)
            let replacement = MergeRenderer.resolve(tokenText, context: context, serialSettings: serialSettings)
            let attrs = tokenRange.location < base.length ? base.attributes(at: tokenRange.location, effectiveRange: nil) : [:]
            base.replaceCharacters(in: tokenRange, with: replacement)
            if !replacement.isEmpty {
                base.setAttributes(attrs, range: NSRange(location: tokenRange.location, length: (replacement as NSString).length))
            }
        }

        if element.verticalTextLayout == true {
            let vertical = NSMutableAttributedString()
            for (lineIndex, line) in base.string.components(separatedBy: .newlines).enumerated() {
                if lineIndex > 0 {
                    vertical.append(NSAttributedString(string: "\n\n"))
                }
                for (charIndex, scalar) in line.enumerated() {
                    let nsIndex = (line as NSString).range(of: String(scalar), options: [], range: NSRange(location: charIndex, length: 1)).location
                    let attrs = nsIndex != NSNotFound && nsIndex < base.length ? base.attributes(at: nsIndex, effectiveRange: nil) : [:]
                    vertical.append(NSAttributedString(string: String(scalar), attributes: attrs))
                    if charIndex < line.count - 1 {
                        vertical.append(NSAttributedString(string: "\n", attributes: attrs))
                    }
                }
            }
            return trimmingTrailingLineBreaks(from: vertical)
        }

        return trimmingTrailingLineBreaks(from: base)
    }

    /// A final CR/LF creates an extra empty layout fragment and shifts the
    /// visible block upward when it is vertically centered. Keep the document
    /// content untouched and remove only those terminal line breaks from the
    /// attributed value used for layout and drawing.
    private static func trimmingTrailingLineBreaks(
        from attributed: NSAttributedString
    ) -> NSAttributedString {
        let string = attributed.string as NSString
        var length = string.length
        while length > 0 {
            let codeUnit = string.character(at: length - 1)
            guard codeUnit == 0x0A || codeUnit == 0x0D else { break }
            length -= 1
        }
        guard length != attributed.length else { return attributed }
        return attributed.attributedSubstring(from: NSRange(location: 0, length: length))
    }

    private static func normalizedRichText(
        _ attributed: NSAttributedString,
        for element: LabelElement
    ) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        mutable.beginEditing()
        // Enumerate the immutable source, not `mutable` (mutating the string
        // being enumerated can re-visit ranges).
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            var updated = attributes
            // Runs keep their own family AND size: both can differ per
            // selection, and element-wide changes rewrite the RTF at edit
            // time (rewritingFontFamily / scalingFontSizes), so the stored
            // run font is authoritative. Only font-less runs fall back to
            // the element-wide style.
            if attributes[.font] == nil {
                updated[.font] = PageRenderer.nsFont(
                    name: element.fontName,
                    size: max(0.1, CGFloat(element.fontSize)),
                    isBold: element.isBold,
                    isItalic: element.isItalic
                )
            }

            let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.alignment = element.textAlignment.nsTextAlignment
            updated[.paragraphStyle] = paragraph

            updated[.foregroundColor] = element.foreground.nsColor
            if updated[.underlineStyle] == nil {
                updated[.underlineStyle] = element.isUnderline ? NSUnderlineStyle.single.rawValue : 0
            }
            mutable.setAttributes(updated, range: range)
        }
        mutable.endEditing()
        return mutable
    }
}

struct CircularTextLayoutResult {
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer

    var glyphRange: NSRange {
        layoutManager.glyphRange(for: textContainer)
    }

    var usedRect: CGRect {
        let range = glyphRange
        guard range.length > 0 else { return .zero }
        return layoutManager.boundingRect(forGlyphRange: range, in: textContainer)
    }

    var lineFragmentRects: [CGRect] {
        let range = glyphRange
        guard range.length > 0 else { return [] }
        var fragments: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: range) {
            rect,
            _,
            _,
            _,
            _ in
            fragments.append(rect)
        }
        return fragments
    }
}

/// TextKit's exclusion paths give every line the ellipse chord available at
/// its vertical position. The same layout object drives the canvas preview and
/// vector PDF output; the inline editor reuses `configureCenteredLayout`.
enum CircularTextLayoutRenderer {
    static func makeLayout(
        attributed: NSAttributedString,
        size: CGSize,
        insets: CGSize
    ) -> CircularTextLayoutResult {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: size)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        layoutManager.usesFontLeading = true
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)

        configureCenteredLayout(
            layoutManager: layoutManager,
            textContainer: textContainer,
            size: size,
            insets: insets
        )
        return CircularTextLayoutResult(
            textStorage: storage,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
    }

    @discardableResult
    static func configureCenteredLayout(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        size: CGSize,
        insets: CGSize,
        initialTopInset: CGFloat? = nil
    ) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 0 }
        textContainer.containerSize = size

        let textStorage = layoutManager.textStorage
        let textLength = textStorage?.length ?? 0
        let constraint = CGSize(
            width: max(1, size.width - (2 * insets.width)),
            height: .greatestFiniteMagnitude
        )
        let measuredHeight = textStorage?.boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height ?? 0
        var topInset = initialTopInset
            ?? max(0, (size.height - min(size.height, ceil(measuredHeight) + 1)) / 2)

        for _ in 0..<8 {
            applyExclusionPaths(
                to: textContainer,
                size: size,
                insets: insets,
                topInset: topInset
            )
            if textLength > 0 {
                layoutManager.invalidateLayout(
                    forCharacterRange: NSRange(location: 0, length: textLength),
                    actualCharacterRange: nil
                )
            }
            layoutManager.ensureLayout(for: textContainer)
            let glyphRange = layoutManager.glyphRange(for: textContainer)
            guard glyphRange.length > 0 else {
                if topInset > 0.5 {
                    topInset = 0
                    continue
                }
                break
            }

            let used = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let correction = (size.height / 2) - used.midY
            guard abs(correction) > 0.25 else { break }
            let next = min(max(0, topInset + correction), max(0, size.height - 1))
            guard abs(next - topInset) > 0.1 else { break }
            topInset = next
        }

        applyExclusionPaths(
            to: textContainer,
            size: size,
            insets: insets,
            topInset: topInset
        )
        if textLength > 0 {
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textLength),
                actualCharacterRange: nil
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        return topInset
    }

    static func exclusionPaths(
        size: CGSize,
        insets: CGSize,
        topInset: CGFloat
    ) -> [NSBezierPath] {
        let bounds = CGRect(origin: .zero, size: size)
        let insetX = min(max(0, insets.width), max(0, (size.width / 2) - 0.5))
        let insetY = min(max(0, insets.height), max(0, (size.height / 2) - 0.5))
        let ellipseRect = bounds.insetBy(dx: insetX, dy: insetY)

        let outsideEllipse = NSBezierPath(rect: bounds)
        outsideEllipse.appendOval(in: ellipseRect)
        outsideEllipse.windingRule = .evenOdd

        var paths = [outsideEllipse]
        let blockedHeight = min(max(0, topInset), max(0, size.height - 0.5))
        if blockedHeight > 0.1 {
            paths.append(
                NSBezierPath(
                    rect: CGRect(
                        x: 0,
                        y: 0,
                        width: size.width,
                        height: blockedHeight
                    )
                )
            )
        }
        return paths
    }

    static func draw(
        attributed: NSAttributedString,
        in rect: CGRect,
        context: CGContext,
        insets: CGSize
    ) {
        guard attributed.length > 0, rect.width > 1, rect.height > 1 else { return }
        let layout = makeLayout(
            attributed: attributed,
            size: rect.size,
            insets: insets
        )
        let glyphRange = layout.glyphRange
        guard glyphRange.length > 0 else { return }

        context.saveGState()
        // TextKit uses a top-left layout coordinate system. Flip only inside
        // the element so the surrounding PDF remains in its normal y-up space.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        layout.layoutManager.drawBackground(
            forGlyphRange: glyphRange,
            at: .zero
        )
        layout.layoutManager.drawGlyphs(
            forGlyphRange: glyphRange,
            at: .zero
        )
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func applyExclusionPaths(
        to textContainer: NSTextContainer,
        size: CGSize,
        insets: CGSize,
        topInset: CGFloat
    ) {
        textContainer.exclusionPaths = exclusionPaths(
            size: size,
            insets: insets,
            topInset: topInset
        )
    }
}

enum CodeImageProvider {
    static let ciContext = CIContext(options: nil)
    // CIFilter generation + rasterization is far too slow to repeat for every
    // preview slot on every refresh; payload+size pairs render once.
    private static let imageCache = NSCache<NSString, NSImage>()

    static func makeImage(for element: LabelElement, context: MergeContext, serialSettings: SerialSettings, unitScale: CGFloat) -> NSImage? {
        let payload = MergeRenderer.resolve(element.content, context: context, serialSettings: serialSettings)
        let pixelSize = CGSize(
            width: max(96, element.frame.width * Double(max(unitScale, CGFloat(mmToPointsRatio))) * 6),
            height: max(64, element.frame.height * Double(max(unitScale, CGFloat(mmToPointsRatio))) * 6)
        )

        let cacheKey = "\(element.type.rawValue)|\(Int(pixelSize.width))x\(Int(pixelSize.height))|\(payload)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let image: NSImage?
        switch element.type {
        case .qrCode:
            image = qr(payload: payload, pixelSize: pixelSize)
        case .code128:
            image = code128(payload: payload, pixelSize: pixelSize)
        default:
            image = nil
        }
        if let image {
            imageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    private static func qr(payload: String, pixelSize: CGSize) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let scaleX = pixelSize.width / output.extent.width
        let scaleY = pixelSize.height / output.extent.height
        let scaled = output.transformed(by: .init(scaleX: scaleX, y: scaleY))
        return rasterize(ciImage: scaled, size: pixelSize)
    }

    private static func code128(payload: String, pixelSize: CGSize) -> NSImage? {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(payload.utf8)
        filter.quietSpace = 7

        guard let output = filter.outputImage else {
            return nil
        }

        let scaleX = pixelSize.width / output.extent.width
        let scaleY = pixelSize.height / output.extent.height
        let scaled = output.transformed(by: .init(scaleX: scaleX, y: scaleY))
        return rasterize(ciImage: scaled, size: pixelSize)
    }

    private static func rasterize(ciImage: CIImage, size: CGSize) -> NSImage? {
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

enum PageRenderer {
    static func pageSize(document: LabelDocument) -> NSSize {
        NSSize(
            width: document.sheet.pageWidthMM * mmToPointsRatio,
            height: document.sheet.pageHeightMM * mmToPointsRatio
        )
    }

    static func hostingView(document: LabelDocument, pageIndex: Int) -> NSHostingView<PageSheetContents> {
        let size = pageSize(document: document)
        let root = PageSheetContents(
            document: document,
            pageIndex: pageIndex,
            unitScale: CGFloat(mmToPointsRatio),
            showGuides: false,
            applyPreviewChrome: false
        )
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return view
    }

    static func renderedImage(document: LabelDocument, pageIndex: Int) -> NSImage? {
        let view = hostingView(document: document, pageIndex: pageIndex)
        let size = pageSize(document: document)
        let scale = printRasterDPI / 72.0
        let pixelsWide = max(1, Int((size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((size.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }

    static func pdfData(document: LabelDocument, pageIndex: Int) -> Data {
        if let vector = directPDFData(document: document, pageIndex: pageIndex),
           let pdf = PDFDocument(data: vector),
           pdf.pageCount > 0 {
            return vector
        }
        return imageBackedPDFData(document: document, pageIndex: pageIndex) ?? Data()
    }

    /// Renders every page of the document into a single multi-page PDF by
    /// merging each page's single-page PDF with PDFKit.
    static func pdfDataAllPages(document: LabelDocument) -> Data {
        let pageCount = max(1, document.pageCount)
        let combined = PDFDocument()
        for pageIndex in 0..<pageCount {
            let data = pdfData(document: document, pageIndex: pageIndex)
            guard let page = PDFDocument(data: data), page.pageCount > 0 else { continue }
            for i in 0..<page.pageCount {
                if let pdfPage = page.page(at: i) {
                    combined.insert(pdfPage, at: combined.pageCount)
                }
            }
        }
        if combined.pageCount == 0 {
            return pdfData(document: document, pageIndex: 0)
        }
        return combined.dataRepresentation() ?? pdfData(document: document, pageIndex: 0)
    }

    static func pngData(document: LabelDocument, pageIndex: Int) -> Data? {
        guard let image = renderedImage(document: document, pageIndex: pageIndex) else {
            return nil
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func print(document: LabelDocument, pageIndex: Int) -> Bool {
        let data = pdfData(document: document, pageIndex: pageIndex)
        if let result = runPrintOperation(document: document, pdfData: data) {
            return result
        }

        let printSize = pageSize(document: document)
        let fallbackView: NSView
        if let image = renderedImage(document: document, pageIndex: pageIndex) {
            fallbackView = printableImageView(image: image, size: printSize)
        } else {
            fallbackView = hostingView(document: document, pageIndex: pageIndex)
        }

        let operation = NSPrintOperation(
            view: fallbackView,
            printInfo: configuredPrintInfo(document: document)
        )
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }

    /// Submits the complete multi-page PDF through one PDFKit print operation,
    /// so every queued label is part of a single macOS/CUPS print job.
    @discardableResult
    static func printAllPages(document: LabelDocument) -> Bool {
        runPrintOperation(
            document: document,
            pdfData: pdfDataAllPages(document: document)
        ) ?? false
    }

    private static func configuredPrintInfo(document: LabelDocument) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.paperSize = pageSize(document: document)
        return info
    }

    /// Nil means the PDF could not be opened as a printable document. A Bool
    /// is the actual result of the one print operation (including cancellation).
    private static func runPrintOperation(
        document: LabelDocument,
        pdfData: Data
    ) -> Bool? {
        guard
            let pdfDocument = PDFDocument(data: pdfData),
            pdfDocument.pageCount > 0,
            let operation = pdfDocument.printOperation(
                for: configuredPrintInfo(document: document),
                scalingMode: PDFPrintScalingMode(rawValue: 0)!,
                autoRotate: false
            )
        else {
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        operation.jobTitle = document.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation.run()
    }

    static func directPDFData(document: LabelDocument, pageIndex: Int) -> Data? {
        let pageSize = pageSize(document: document)
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageSize.width, height: pageSize.height))
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return nil
        }

        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)

        for row in 0..<document.sheet.rows {
            for column in 0..<document.sheet.columns {
                let slotIndex = row * document.sheet.columns + column
                let payload = document.renderPayload(slotIndex: slotIndex, pageIndex: pageIndex)
                guard payload.context.isActive || !document.hasFiniteMergeRows else { continue }

                let slot = document.sheet.slotFrame(column: column, row: row)
                let slotRect = CGRect(
                    x: mmToPoints(slot.x),
                    y: pageSize.height - mmToPoints(slot.y + slot.height),
                    width: mmToPoints(slot.width),
                    height: mmToPoints(slot.height)
                )

                context.saveGState()
                clip(to: slotRect, shape: document.sheet.shape, radiusMM: document.sheet.cornerRadiusMM, in: context)

                for element in payload.elements {
                    draw(
                        element: element,
                        inSlotRect: slotRect,
                        labelShape: document.sheet.shape,
                        context: context,
                        mergeContext: payload.context,
                        serialSettings: payload.serialSettings
                    )
                }

                context.restoreGState()
            }
        }

        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    static func imageBackedPDFData(document: LabelDocument, pageIndex: Int) -> Data? {
        guard let image = renderedImage(document: document, pageIndex: pageIndex),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let pageSize = pageSize(document: document)
        var mediaBox = CGRect(origin: .zero, size: CGSize(width: pageSize.width, height: pageSize.height))
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            return nil
        }

        context.beginPDFPage(nil)
        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        context.draw(cgImage, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        return output as Data
    }

    static func writeTemporaryPDF(document: LabelDocument, pageIndex: Int) -> URL? {
        let data = pdfData(document: document, pageIndex: pageIndex)
        guard !data.isEmpty else {
            return nil
        }
        let safeTitle = document.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iLabel2Mac-\(safeTitle)-p\(pageIndex + 1)-\(UUID().uuidString).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func writeTemporaryPrintPDF(document: LabelDocument, pageIndex: Int) -> URL? {
        let data = directPDFData(document: document, pageIndex: pageIndex)
            ?? imageBackedPDFData(document: document, pageIndex: pageIndex)
            ?? Data()
        guard !data.isEmpty else {
            return nil
        }
        let safeTitle = document.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iLabel2Mac-print-\(safeTitle)-p\(pageIndex + 1)-\(UUID().uuidString).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    static func printableImageView(image: NSImage, size: NSSize) -> NSImageView {
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        return imageView
    }

    static func clip(to rect: CGRect, shape: LabelShape, radiusMM: Double, in context: CGContext) {
        context.addPath(shapePath(in: rect, shape: shape, radiusMM: radiusMM))
        context.clip()
    }

    static func shapePath(in rect: CGRect, shape: LabelShape, radiusMM: Double) -> CGPath {
        switch shape {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .roundedRectangle:
            let radius = mmToPoints(radiusMM)
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .capsule:
            let radius = rect.height / 2
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        }
    }

    static func draw(
        element: LabelElement,
        inSlotRect slotRect: CGRect,
        labelShape: LabelShape,
        context: CGContext,
        mergeContext: MergeContext,
        serialSettings: SerialSettings
    ) {
        let rect = CGRect(
            x: slotRect.origin.x + mmToPoints(element.frame.x),
            y: slotRect.origin.y + (slotRect.height - mmToPoints(element.frame.y) - mmToPoints(element.frame.height)),
            width: mmToPoints(element.frame.width),
            height: mmToPoints(element.frame.height)
        )

        context.saveGState()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(element.rotation) * .pi / 180)
        context.translateBy(x: -center.x, y: -center.y)
        context.setAlpha(CGFloat(element.opacity))

        switch element.type {
        case .text:
            drawText(
                element: element,
                rect: rect,
                context: context,
                mergeContext: mergeContext,
                serialSettings: serialSettings,
                usesCircularFlow: labelShape == .circle
                    && element.usesCircularTextFlow == true
            )
        case .rectangle:
            drawRectangle(element: element, rect: rect, context: context)
        case .image:
            drawImageElement(element: element, rect: rect, context: context)
        case .qrCode, .code128:
            drawCodeElement(element: element, rect: rect, context: context, mergeContext: mergeContext, serialSettings: serialSettings)
        }

        context.restoreGState()
    }

    static func drawText(
        element: LabelElement,
        rect: CGRect,
        context: CGContext,
        mergeContext: MergeContext,
        serialSettings: SerialSettings,
        usesCircularFlow: Bool = false
    ) {
        let surfacePath: CGPath
        if usesCircularFlow {
            surfacePath = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let radius = mmToPoints(element.cornerRadiusMM)
            surfacePath = CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            )
        }
        context.addPath(surfacePath)
        context.setFillColor(element.background.nsColor.cgColor)
        context.fillPath()
        if element.strokeWidth > 0 {
            context.addPath(surfacePath)
            context.setStrokeColor(element.stroke.nsColor.cgColor)
            context.setLineWidth(CGFloat(element.strokeWidth))
            context.strokePath()
        }

        let attributed = TextLayoutRenderer.attributedString(for: element, context: mergeContext, serialSettings: serialSettings)
        if usesCircularFlow {
            CircularTextLayoutRenderer.draw(
                attributed: attributed,
                in: rect,
                context: context,
                insets: CGSize(
                    width: mmToPoints(textElementInsetXMM),
                    height: mmToPoints(textElementInsetYMM)
                )
            )
            return
        }
        // Same mm insets as the on-screen surfaces (textElementInset*MM) so
        // line wrapping happens at the same characters in print as on screen.
        let insetRect = rect.insetBy(dx: mmToPoints(textElementInsetXMM), dy: mmToPoints(textElementInsetYMM))
        let textSize = attributed.boundingRect(
            with: insetRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let drawHeight = min(insetRect.height, ceil(textSize.height) + 1)
        let drawRect = CGRect(
            x: insetRect.origin.x,
            y: insetRect.midY - (drawHeight / 2),
            width: insetRect.width,
            height: drawHeight
        )

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawRectangle(element: LabelElement, rect: CGRect, context: CGContext) {
        let radius = mmToPoints(element.cornerRadiusMM)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path)
        context.setFillColor(element.background.nsColor.cgColor)
        context.fillPath()
        if element.strokeWidth > 0 {
            context.addPath(path)
            context.setStrokeColor(element.stroke.nsColor.cgColor)
            context.setLineWidth(CGFloat(element.strokeWidth))
            context.strokePath()
        }
    }

    static func drawImageElement(element: LabelElement, rect: CGRect, context: CGContext) {
        guard let imageData = element.imageData, let image = NSImage(data: imageData) else { return }
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(element.opacity))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawCodeElement(
        element: LabelElement,
        rect: CGRect,
        context: CGContext,
        mergeContext: MergeContext,
        serialSettings: SerialSettings
    ) {
        guard let image = CodeImageProvider.makeImage(
            for: element,
            context: mergeContext,
            serialSettings: serialSettings,
            unitScale: CGFloat(mmToPointsRatio)
        ) else { return }
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: CGFloat(element.opacity))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func nsFont(name: String, size: CGFloat, isBold: Bool, isItalic: Bool) -> NSFont {
        resolvedNSFont(name: name, size: size, isBold: isBold, isItalic: isItalic)
    }
}

extension DateFormatter {
    static let shortISO: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }()

    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
