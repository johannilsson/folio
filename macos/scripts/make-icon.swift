// Draws the Folio app icon and writes macos/Resources/AppIcon.icns.
// Usage: swift macos/scripts/make-icon.swift [output.icns]
//
// A page with a heading, text lines and a highlighted phrase, with a comment bubble
// on its corner, on a purple rounded square: the markdown file plus its annotations.
import AppKit

let master: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws the icon on a 1024-point canvas; the caller scales the context for other sizes.
func draw(_ c: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()

    // macOS icon grid: an 824pt rounded square centred in the 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
    c.addPath(bodyPath)
    c.setFillColor(rgb(0x6d28d9))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(bodyPath)
    c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [rgb(0xa78bfa), rgb(0x6d28d9)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A soft sheen over the upper half.
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xffffff, 0.18), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 512), options: [])
    c.restoreGState()

    // The page.
    let sheet = CGRect(x: 285, y: 205, width: 454, height: 590)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0x2e1065, 0.40))
    c.addPath(roundedRect(sheet, 38))
    c.setFillColor(rgb(0xffffff))
    c.fillPath()
    c.restoreGState()

    let left: CGFloat = 340
    let fullWidth: CGFloat = 344

    // Heading.
    c.addPath(roundedRect(CGRect(x: left, y: 686, width: 240, height: 38), 19))
    c.setFillColor(rgb(0x2e2557))
    c.fillPath()

    // Text lines, the second with a highlighted phrase behind it.
    c.addPath(roundedRect(CGRect(x: left - 6, y: 566, width: 232, height: 44), 12))
    c.setFillColor(rgb(0xfcd34d))
    c.fillPath()
    let lines: [(y: CGFloat, x: CGFloat, width: CGFloat)] = [
        (626, left, fullWidth),
        (576, left + 242, fullWidth - 242),  // the rest of the highlighted line
        (526, left, fullWidth),
        (476, left, 214),
    ]
    for line in lines {
        c.addPath(roundedRect(CGRect(x: line.x, y: line.y, width: line.width, height: 26), 13))
        c.setFillColor(rgb(0xc9c3e3))
        c.fillPath()
    }
    c.addPath(roundedRect(CGRect(x: left, y: 576, width: 220, height: 26), 13))
    c.setFillColor(rgb(0x4c3f8f))
    c.fillPath()

    // The comment bubble, hanging off the page's lower corner.
    let bubble = CGRect(x: 540, y: 222, width: 270, height: 178)
    let bubblePath = CGMutablePath()
    bubblePath.addPath(roundedRect(bubble, 58))
    bubblePath.move(to: CGPoint(x: 600, y: 232))
    bubblePath.addLine(to: CGPoint(x: 566, y: 168))
    bubblePath.addLine(to: CGPoint(x: 668, y: 232))
    bubblePath.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x2e1065, 0.45))
    c.addPath(bubblePath)
    c.setFillColor(rgb(0xfcd34d))
    c.fillPath()
    c.restoreGState()

    c.setFillColor(rgb(0x5b21b6))
    for x in [610, 675, 740] as [CGFloat] {
        c.fillEllipse(in: CGRect(x: x - 17, y: 311 - 17, width: 34, height: 34))
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.cgContext.scaleBy(x: CGFloat(size) / master, y: CGFloat(size) / master)
    context.cgContext.interpolationQuality = .high
    draw(context.cgContext)
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.icns").path)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Folio-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

// Each size is drawn fresh rather than scaled down, so small icons stay crisp.
for (name, size) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    try png(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

// A picture to look at, next to the icon.
try png(size: 512).write(to: output.deletingPathExtension().appendingPathExtension("png"))
try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
