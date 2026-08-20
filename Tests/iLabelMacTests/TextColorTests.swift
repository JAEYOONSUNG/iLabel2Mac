import AppKit
import XCTest
@testable import iLabelMac

final class TextColorTests: XCTestCase {
    private func rtfData(_ attributed: NSAttributedString) throws -> Data {
        try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ))
    }

    /// Colors survive an RTF round trip and a color-space conversion with a
    /// little drift, so compare both sides in the same space instead of against
    /// literal components.
    private func assertSameColor(
        _ actual: NSColor?,
        _ expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let lhs = try XCTUnwrap(actual?.usingColorSpace(.deviceRGB), file: file, line: line)
        let rhs = try XCTUnwrap(expected.usingColorSpace(.deviceRGB), file: file, line: line)
        XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 0.02, file: file, line: line)
    }

    private func mergeContext() -> MergeContext {
        MergeContext(
            row: [:],
            serialValue: 1,
            rowNumber: 1,
            pageNumber: 1,
            slotNumber: 1,
            isActive: true
        )
    }

    func testSingleColorTextStillFollowsTheElementColor() throws {
        // Every label made before per-selection color has one color baked into
        // its runs. The inspector must keep repainting those, or changing the
        // color would silently do nothing to existing text.
        var element = LabelElement.make(.text, index: 1)
        element.content = "hello"
        element.foreground = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        element.richTextRTF = try rtfData(NSAttributedString(
            string: "hello",
            attributes: [.foregroundColor: NSColor.black]
        ))

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: mergeContext(),
            serialSettings: .default
        )

        try assertSameColor(
            rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            element.foreground.nsColor
        )
    }

    func testMultiColorTextKeepsEachRunColor() throws {
        // Once a selection is colored, the element-wide color must stop
        // overriding — otherwise the coloring survives on screen but is lost in
        // the preview and the print.
        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "ab", attributes: [.foregroundColor: NSColor.red]))
        mixed.append(NSAttributedString(string: "cd", attributes: [.foregroundColor: NSColor.blue]))

        var element = LabelElement.make(.text, index: 1)
        element.content = "abcd"
        element.foreground = .black
        element.richTextRTF = try rtfData(mixed)

        let rendered = TextLayoutRenderer.attributedString(
            for: element,
            context: mergeContext(),
            serialSettings: .default
        )

        let first = try XCTUnwrap(
            (rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.deviceRGB)
        )
        let last = try XCTUnwrap(
            (rendered.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)?
                .usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(first.redComponent, 0.9)
        XCTAssertGreaterThan(last.blueComponent, 0.9)
    }

    func testElementWideColorChangeRepaintsEveryRun() throws {
        // The element-wide action deliberately collapses a multi-color element
        // back to one color, so the inspector stays the single source of truth.
        let mixed = NSMutableAttributedString()
        mixed.append(NSAttributedString(string: "ab", attributes: [.foregroundColor: NSColor.red]))
        mixed.append(NSAttributedString(string: "cd", attributes: [.foregroundColor: NSColor.blue]))
        let data = try rtfData(mixed)

        let green = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        let rewritten = try XCTUnwrap(LabelElement.rewritingForegroundColor(of: data, to: green))
        let decoded = try XCTUnwrap(try? NSAttributedString(
            data: rewritten,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ))

        XCTAssertFalse(LabelElement.usesPerRunForegroundColor(decoded))
        for index in 0..<decoded.length {
            try assertSameColor(
                decoded.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                green.nsColor
            )
        }
    }

    func testColorDetectionIgnoresRoundTripDrift() throws {
        // An RTF round trip perturbs components slightly; that must not read as
        // "the user colored a selection".
        let uniform = NSAttributedString(string: "abcd", attributes: [.foregroundColor: NSColor.red])
        let decoded = try XCTUnwrap(try? NSAttributedString(
            data: try rtfData(uniform),
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ))
        XCTAssertFalse(LabelElement.usesPerRunForegroundColor(decoded))
    }
}
