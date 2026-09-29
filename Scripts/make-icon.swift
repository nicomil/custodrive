// Draws Custodrive's app icon: an external drive guarded by a shield.
// Usage: swift Scripts/make-icon.swift OUTPUT.iconset
import AppKit

let output = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, colors: [NSColor]) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        .applying(.init(paletteColors: colors))
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}

func draw(_ side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = side * 0.1
    let tile = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.012)
    shadow.shadowBlurRadius = side * 0.025
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.45, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.52, blue: 0.62, alpha: 1)])!
        .draw(in: shape, angle: 70)
    if let drive = symbol("externaldrive.fill", size: side * 0.40, weight: .regular, colors: [.white]) {
        let size = drive.size
        drive.draw(in: NSRect(x: (side - size.width) / 2 - side * 0.04, y: side * 0.40,
                              width: size.width, height: size.height))
    }
    let green = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)
    if let shield = symbol("checkmark.shield.fill", size: side * 0.27, weight: .bold,
                           colors: [.white, green]) {
        let size = shield.size
        shield.draw(in: NSRect(x: side * 0.55, y: side * 0.17, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
