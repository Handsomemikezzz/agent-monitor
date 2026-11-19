// Draws the menu bar badge: three rounded boxes with a count in each,
// waiting (red) · done (green) · other sessions (grey).
//
//   agent-status-render 2 1 0   → prints a base64 PNG on stdout
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

let boxes: [(fill: String, stroke: String)] = [
    ("#FFC9C9", "#E03131"),  // waiting for you
    ("#B2F2BB", "#2F9E44"),  // done, not seen yet
    ("#E9ECEF", "#ADB5BD"),  // everything else
]
let counts = CommandLine.arguments.dropFirst().map { Int($0) ?? 0 }

let boxW: CGFloat = 22, boxH: CGFloat = 17, gap: CGFloat = 2
let lineW: CGFloat = 1.5, radius: CGFloat = 5, scale: CGFloat = 2
let width = CGFloat(boxes.count) * boxW + CGFloat(boxes.count - 1) * gap
let height: CGFloat = 18

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

for (i, box) in boxes.enumerated() {
    let x = CGFloat(i) * (boxW + gap)
    let rect = NSRect(x: x + lineW / 2, y: (height - boxH) / 2 + lineW / 2,
                      width: boxW - lineW, height: boxH - lineW)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color(box.fill).setFill()
    path.fill()
    color(box.stroke).setStroke()
    path.lineWidth = lineW
    path.stroke()

    let n = i < counts.count ? counts[i] : 0
    let text = n > 99 ? "99+" : String(n)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: roundedFont(text.count > 2 ? 9 : 11.5),
        .foregroundColor: color("#1E1E1E"),
    ]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
              withAttributes: attrs)
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
print(png.base64EncodedString())
