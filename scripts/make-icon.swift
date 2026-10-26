// Draws the app icon. Run: swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o assets/AppIcon.icns
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s),
                          xRadius: 185 * s, yRadius: 185 * s)
    NSColor(srgbRed: 0.043, green: 0.047, blue: 0.059, alpha: 1).setFill()
    bg.fill()
    NSColor(white: 1, alpha: 0.08).setStroke()
    bg.lineWidth = 6 * s
    bg.stroke()
    // Two panes, Mac blue and PC green, with a prompt chevron each.
    let colors = [NSColor(srgbRed: 0.43, green: 0.66, blue: 1, alpha: 1),
                  NSColor(srgbRed: 0.37, green: 0.83, blue: 0.60, alpha: 1)]
    for (i, c) in colors.enumerated() {
        let x = (200 + CGFloat(i) * 324) * s
        let pane = NSBezierPath(roundedRect: NSRect(x: x, y: 250 * s, width: 300 * s, height: 524 * s),
                                xRadius: 44 * s, yRadius: 44 * s)
        NSColor(srgbRed: 0.06, green: 0.067, blue: 0.082, alpha: 1).setFill()
        pane.fill()
        c.setStroke()
        pane.lineWidth = 10 * s
        pane.stroke()
        let chev = NSBezierPath()
        chev.move(to: NSPoint(x: x + 70 * s, y: 600 * s))
        chev.line(to: NSPoint(x: x + 140 * s, y: 540 * s))
        chev.line(to: NSPoint(x: x + 70 * s, y: 480 * s))
        chev.lineWidth = 26 * s
        chev.lineCapStyle = .round
        chev.lineJoinStyle = .round
        chev.stroke()
        let bar = NSBezierPath(roundedRect: NSRect(x: x + 160 * s, y: 468 * s, width: 70 * s, height: 24 * s),
                               xRadius: 12 * s, yRadius: 12 * s)
        c.withAlphaComponent(0.6).setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
print("wrote \(dir.path)")
