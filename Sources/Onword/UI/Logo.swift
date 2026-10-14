import AppKit
import SwiftUI

/// Onword's mark: waveform bars (your voice) ending in a text cursor (where the words land).
/// Same geometry as scripts/make-icon.swift, which renders the app icon.
enum Logo {
    /// The glyph as two shapes in `box` (a square, y-up): the bars and the cursor.
    /// `boldness` thickens the cursor for tiny renderings (the menu bar).
    static func paths(in box: CGRect, boldness: CGFloat = 1) -> (bars: CGPath, cursor: CGPath) {
        let s = box.width / 1024
        let cy = box.midY
        let barWidth = 66 * s, gap = 40 * s
        let heights: [CGFloat] = [170, 330, 470, 290].map { $0 * s }
        let cursorHeight = 540 * s, stem = 30 * s * boldness, serifWidth = 104 * s, serifHeight = 28 * s * boldness
        let groupWidth = CGFloat(heights.count) * (barWidth + gap) + 30 * s + serifWidth
        var x = box.midX - groupWidth / 2

        let bars = CGMutablePath()
        for h in heights {
            bars.addRoundedRect(in: CGRect(x: x, y: cy - h / 2, width: barWidth, height: h),
                                cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
            x += barWidth + gap
        }
        let cx = x + 30 * s + serifWidth / 2
        let cursor = CGMutablePath()
        cursor.addRoundedRect(in: CGRect(x: cx - stem / 2, y: cy - cursorHeight / 2, width: stem, height: cursorHeight),
                              cornerWidth: stem / 2, cornerHeight: stem / 2)
        for y in [cy + cursorHeight / 2 - serifHeight, cy - cursorHeight / 2] {
            cursor.addRoundedRect(in: CGRect(x: cx - serifWidth / 2, y: y, width: serifWidth, height: serifHeight),
                                  cornerWidth: serifHeight / 2, cornerHeight: serifHeight / 2)
        }
        return (bars, cursor)
    }

    /// Lavender of the cursor (dawn-700), the same in light and dark.
    static let accent = Color(red: 0.604, green: 0.361, blue: 0.753)

    /// Monochrome template for the menu bar; macOS tints it for light/dark menu bars.
    /// Bolder cursor than the app icon so it stays crisp at 18 pt.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { rect in
            let glyph = paths(in: CGRect(x: rect.midX - 15, y: rect.midY - 15, width: 30, height: 30), boldness: 2.2)
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(.black)
            cg.addPath(glyph.bars)
            cg.addPath(glyph.cursor)
            cg.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The app icon at full resolution. `NSApp.applicationIconImage` scales up a small version, which looks
/// soft at the welcome screen's 220 pt; this draws the icon's 1024 px version.
enum AppIconImage {
    static let image: Image = {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
        let best = icon?.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }
        if let cg = best?.cgImage { return Image(decorative: cg, scale: 1) }
        return Image(nsImage: NSApp.applicationIconImage)
    }()
}

/// The mark in full colour, for the sidebar. Drawn with SwiftUI so the ink colour follows the Hub's
/// Light/Dark setting (AppKit drawing would follow the system appearance instead).
struct LogoMark: View {
    var size: CGFloat = 24

    var body: some View {
        Canvas { context, canvasSize in
            let glyph = Logo.paths(in: CGRect(origin: .zero, size: canvasSize))
            // CGPath is y-up; SwiftUI's canvas is y-down.
            let flip = CGAffineTransform(translationX: 0, y: canvasSize.height).scaledBy(x: 1, y: -1)
            context.fill(Path(glyph.bars).applying(flip), with: .color(Theme.ink))
            context.fill(Path(glyph.cursor).applying(flip), with: .color(Logo.accent))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
