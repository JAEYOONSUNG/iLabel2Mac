import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resourcesURL = projectRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let iconName = "AppIcon"

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "icon", code: 1)
    }
    try png.write(to: url, options: .atomic)
}

func drawMark(in rect: NSRect) {
    let dotRect = NSRect(
        x: rect.minX + rect.width * 0.31,
        y: rect.minY + rect.height * 0.73,
        width: rect.width * 0.20,
        height: rect.width * 0.20
    )
    NSBezierPath(ovalIn: dotRect).fill()

    let body = NSBezierPath()
    body.move(to: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.minY + rect.height * 0.19))
    body.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.53),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.30),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.43)
    )
    body.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.65),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.58),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.minY + rect.height * 0.64)
    )
    body.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.56, y: rect.minY + rect.height * 0.31),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.51, y: rect.minY + rect.height * 0.55),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.57, y: rect.minY + rect.height * 0.40)
    )
    body.curve(
        to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.minY + rect.height * 0.28),
        controlPoint1: CGPoint(x: rect.minX + rect.width * 0.49, y: rect.minY + rect.height * 0.25),
        controlPoint2: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.25)
    )
    body.close()
    body.fill()
}

func renderIcon(masterSize: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: masterSize, height: masterSize))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: masterSize, height: masterSize)
    NSGraphicsContext.current?.imageInterpolation = .high

    let backgroundInset = masterSize * 0.08
    let backgroundRect = rect.insetBy(dx: backgroundInset, dy: backgroundInset)
    let circle = NSBezierPath(ovalIn: backgroundRect)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.18, blue: 0.41, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.60, alpha: 1)
    ])!
    gradient.draw(in: circle, angle: -90)

    NSColor.white.setFill()
    drawMark(in: backgroundRect.insetBy(dx: backgroundRect.width * 0.08, dy: backgroundRect.height * 0.08))

    let ring = NSBezierPath(ovalIn: backgroundRect.insetBy(dx: 1.5, dy: 1.5))
    NSColor.white.withAlphaComponent(0.12).setStroke()
    ring.lineWidth = max(2, masterSize * 0.012)
    ring.stroke()

    image.unlockFocus()
    return image
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, filename) in sizes {
    try writePNG(renderIcon(masterSize: CGFloat(size)), to: iconsetURL.appendingPathComponent(filename))
}

let icnsURL = resourcesURL.appendingPathComponent("\(iconName).icns")
try? FileManager.default.removeItem(at: icnsURL)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}

print(icnsURL.path)
