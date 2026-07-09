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
            return NSAttributedString(string: text, attributes: attributes)
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
            return vertical
        }

        return base
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
        if let vector = directPDFData(document: document, pageIndex: pageIndex), vector.count > 2048 {
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
        let printSize = pageSize(document: document)
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.paperSize = printSize

        if let pdfURL = writeTemporaryPrintPDF(document: document, pageIndex: pageIndex),
           let pdfDocument = PDFDocument(url: pdfURL),
           let operation = pdfDocument.printOperation(
            for: info,
            scalingMode: PDFPrintScalingMode(rawValue: 0)!,
            autoRotate: false
           ) {
            NSApp.activate(ignoringOtherApps: true)
            operation.jobTitle = document.title
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            return operation.run()
        }

        let fallbackView: NSView
        if let image = renderedImage(document: document, pageIndex: pageIndex) {
            fallbackView = printableImageView(image: image, size: printSize)
        } else {
            fallbackView = hostingView(document: document, pageIndex: pageIndex)
        }

        let operation = NSPrintOperation(view: fallbackView, printInfo: info)
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
                let mergeContext = document.mergeContext(slotIndex: slotIndex, pageIndex: pageIndex)
                guard mergeContext.isActive || !document.hasFiniteMergeRows else { continue }

                let slot = document.sheet.slotFrame(column: column, row: row)
                let slotRect = CGRect(
                    x: mmToPoints(slot.x),
                    y: pageSize.height - mmToPoints(slot.y + slot.height),
                    width: mmToPoints(slot.width),
                    height: mmToPoints(slot.height)
                )

                context.saveGState()
                clip(to: slotRect, shape: document.sheet.shape, radiusMM: document.sheet.cornerRadiusMM, in: context)

                for element in document.elements {
                    draw(
                        element: element,
                        inSlotRect: slotRect,
                        context: context,
                        mergeContext: mergeContext,
                        serialSettings: document.serial
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
            drawText(element: element, rect: rect, context: context, mergeContext: mergeContext, serialSettings: serialSettings)
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
        serialSettings: SerialSettings
    ) {
        let attributed = TextLayoutRenderer.attributedString(for: element, context: mergeContext, serialSettings: serialSettings)
        // Same mm insets as the on-screen surfaces (textElementInset*MM) so
        // line wrapping happens at the same characters in print as on screen.
        let insetRect = rect.insetBy(dx: mmToPoints(textElementInsetXMM), dy: mmToPoints(textElementInsetYMM))
        let textSize = attributed.boundingRect(
            with: insetRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let drawRect = CGRect(
            x: insetRect.origin.x,
            y: insetRect.origin.y + max(0, (insetRect.height - textSize.height) / 2),
            width: insetRect.width,
            height: min(insetRect.height, textSize.height + 1)
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
