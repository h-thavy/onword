// Generates Onword's app icon: Resources/AppIcon.icns (+ Resources/AppIcon.png for docs).
//
//   swift scripts/make-icon.swift
//
// The mark: waveform bars (your voice) ending in a text cursor (where the words land), in the app's
// sand / ink / lavender palette, on the macOS icon grid (824 pt rounded square on a 1024 canvas).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? ".")
let resources = root.appendingPathComponent("Resources")

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Same geometry as `Logo.drawGlyph` in the app, in a 1024-unit box.
func drawGlyph(in box: CGRect, ink: NSColor, accent: NSColor) {
    let s = box.width / 1024
    let cy = box.midY
    let barWidth = 66 * s, gap = 40 * s
    let heights: [CGFloat] = [170, 330, 470, 290].map { $0 * s }
    let cursorHeight = 540 * s, stem = 30 * s, serifWidth = 104 * s, serifHeight = 28 * s
    let groupWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count) * gap + 30 * s + serifWidth
    var x = box.midX - groupWidth / 2

    ink.setFill()
    for h in heights {
        NSBezierPath(roundedRect: CGRect(x: x, y: cy - h / 2, width: barWidth, height: h),
                     xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    let cx = x + 30 * s + serifWidth / 2
    accent.setFill()
    NSBezierPath(roundedRect: CGRect(x: cx - stem / 2, y: cy - cursorHeight / 2, width: stem, height: cursorHeight),
                 xRadius: stem / 2, yRadius: stem / 2).fill()
    for y in [cy + cursorHeight / 2 - serifHeight, cy - cursorHeight / 2] {
        NSBezierPath(roundedRect: CGRect(x: cx - serifWidth / 2, y: y, width: serifWidth, height: serifHeight),
                     xRadius: serifHeight / 2, yRadius: serifHeight / 2).fill()
    }
}

func icon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Soft drop shadow, as on standard macOS icons.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0xEEEBE3).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Sand body with a gentle top-to-bottom gradient and a hairline edge.
    NSGradient(starting: color(0xFDFCF9), ending: color(0xECE8DE))!.draw(in: shape, angle: -90)
    color(0xDDD8CB).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    drawGlyph(in: CGRect(x: 127, y: 127, width: 770, height: 770), ink: color(0x1A1A1A), accent: color(0x9A5CC0))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! icon(size: base * scale).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
try! icon(size: 1024).representation(using: .png, properties: [:])!.write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
