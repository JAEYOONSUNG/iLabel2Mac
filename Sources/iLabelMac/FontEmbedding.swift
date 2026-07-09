import AppKit
import CoreText
import Foundation

/// Bundles the font files a document actually uses into the project so custom
/// (non-system) fonts render identically on machines where they aren't
/// installed. System fonts (under /System) ship on every Mac, so they are never
/// embedded — that keeps projects small and avoids embedding protected faces.
enum FontEmbedder {
    /// Collect embeddable font files referenced by the document's text.
    static func collect(from document: LabelDocument) -> [EmbeddedFont] {
        var byPostScriptName: [String: EmbeddedFont] = [:]

        func consider(_ font: NSFont) {
            let postScriptName = font.fontName
            guard byPostScriptName[postScriptName] == nil else { return }
            guard
                let url = fontFileURL(for: font),
                !isSystemFont(url),
                let data = try? Data(contentsOf: url)
            else { return }
            byPostScriptName[postScriptName] = EmbeddedFont(
                postScriptName: postScriptName,
                familyName: font.familyName ?? postScriptName,
                data: data
            )
        }

        for element in document.elements where element.type == .text {
            consider(resolvedNSFont(
                name: element.fontName,
                size: 12,
                isBold: element.isBold,
                isItalic: element.isItalic
            ))

            // Inline bold/italic runs live in the RTF with their own font faces.
            if let data = element.richTextRTF,
               let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
               ) {
                attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, _ in
                    if let font = value as? NSFont {
                        consider(font)
                    }
                }
            }
        }

        return byPostScriptName.values.sorted { $0.postScriptName < $1.postScriptName }
    }

    /// Register embedded fonts that this machine doesn't already have. Process
    /// scope means the registration lasts only for this app run and never
    /// installs anything into the user's font library.
    static func register(_ fonts: [EmbeddedFont]?) {
        guard let fonts else { return }
        for font in fonts {
            if NSFont(name: font.postScriptName, size: 12) != nil { continue }
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ilabel2mac-embedded-\(font.postScriptName).font")
            do {
                try font.data.write(to: tempURL, options: .atomic)
                CTFontManagerRegisterFontsForURL(tempURL as CFURL, .process, nil)
            } catch {
                continue
            }
        }
    }

    private static func fontFileURL(for font: NSFont) -> URL? {
        let ctFont = font as CTFont
        return CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL
    }

    private static func isSystemFont(_ url: URL) -> Bool {
        url.path.hasPrefix("/System/")
    }
}
