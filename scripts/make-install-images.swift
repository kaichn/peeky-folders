// Renders the small illustrations used in the README's install steps.
// Everything is drawn here; nothing is captured from the screen.
//
// Usage: swift scripts/make-install-images.swift "build/Peeky Folders.app" docs/install
import AppKit

let args = CommandLine.arguments
let appPath = args.count > 1 ? args[1] : "build/Peeky Folders.app"
let outDir = args.count > 2 ? args[2] : "docs/install"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let icon = NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: appPath).standardizedFileURL.path)

func render(_ size: NSSize, _ name: String, _ draw: (NSRect) -> Void) {
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    print("wrote \(outDir)/\(name).png")
}

func card(_ r: NSRect) {
    NSColor(white: 0.965, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
}

func text(_ s: String, _ p: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular,
          color: NSColor = .black, center: Bool = false, width: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color]
    let str = NSAttributedString(string: s, attributes: attrs)
    var point = p
    if center { point.x += (width - str.size().width) / 2 }
    str.draw(at: point)
}

// Step 2: the Quick Look extension row with its switch turned on.
render(NSSize(width: 420, height: 150), "extension") { r in
    card(r)
    text("Quick Look", NSPoint(x: 24, y: 112), size: 13, weight: .semibold, color: .secondaryLabelColor)
    let row = NSRect(x: 16, y: 20, width: r.width - 32, height: 78)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: row, xRadius: 12, yRadius: 12).fill()
    icon.draw(in: NSRect(x: row.minX + 14, y: row.minY + 11, width: 56, height: 56))
    text("Peeky Folders", NSPoint(x: row.minX + 82, y: row.minY + 40), size: 15, weight: .semibold)
    text("Previews folders and archives", NSPoint(x: row.minX + 82, y: row.minY + 20), size: 12,
         color: .secondaryLabelColor)
    // Switch, on.
    let sw = NSRect(x: row.maxX - 70, y: row.midY - 14, width: 52, height: 28)
    NSColor.systemGreen.setFill()
    NSBezierPath(roundedRect: sw, xRadius: 14, yRadius: 14).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: sw.maxX - 26, y: sw.minY + 2, width: 24, height: 24)).fill()
}

// Step 3: a space bar keycap.
render(NSSize(width: 420, height: 150), "space") { r in
    card(r)
    let key = NSRect(x: 60, y: 42, width: r.width - 120, height: 66)
    NSColor(white: 0.82, alpha: 1).setFill()
    NSBezierPath(roundedRect: key.offsetBy(dx: 0, dy: -4), xRadius: 14, yRadius: 14).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: key, xRadius: 14, yRadius: 14).fill()
    text("space", NSPoint(x: key.minX, y: key.minY + 22), size: 18, weight: .medium,
         color: .secondaryLabelColor, center: true, width: key.width)
}
