// Draws the menu bar badge: one rounded pill split into three coloured segments,
// each holding a count: waiting for you (yellow) · running (green) · done, unread (blue).
//
//   agent-status-render 2 1 3   → prints a base64 PNG on stdout
//
// The PNG is drawn at 2x and tagged 144 dpi, so it shows crisp at its point size.
// Built once by `agent-status install` with: swiftc -O src/render.swift -o build/agent-status-render

import AppKit

func color(_ hex: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let segments: [(fill: String, edge: String)] = [
    ("#FFE066", "#F59F00"),  // waiting for you
    ("#B2F2BB", "#2F9E44"),  // running
    ("#A5D8FF", "#1971C2"),  // done, not seen yet
]
let counts = CommandLine.arguments.dropFirst().map { Int($0) ?? 0 }

let segW: CGFloat = 21, pillH: CGFloat = 17, height: CGFloat = 18
let lineW: CGFloat = 1.5, radius: CGFloat = 6, scale: CGFloat = 2
let width = CGFloat(segments.count) * segW

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func roundedFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .semibold)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
        return f
    }
    return base
}

// The outline sits just inside the image so its stroke isn't cut off.
let pill = NSRect(x: lineW / 2, y: (height - pillH) / 2 + lineW / 2,
                  width: width - lineW, height: pillH - lineW)
let outline = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
outline.lineWidth = lineW

for (i, seg) in segments.enumerated() {
    let slice = NSRect(x: CGFloat(i) * segW, y: 0, width: segW, height: height)

    // Fill this segment's share of the pill, then the outline over it in the
    // segment's own colour, so the edge changes colour with the fill.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: slice).addClip()
    color(seg.fill).setFill()
    outline.fill()
    color(seg.edge).setStroke()
    outline.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let n = i < counts.count ? counts[i] : 0
    let text = n > 99 ? "99+" : String(n)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(text.count > 2 ? 9 : 11.5),
        .foregroundColor: color("#1E1E1E"),
    ]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: slice.midX - size.width / 2, y: pill.midY - size.height / 2),
              withAttributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
print(png.base64EncodedString())
