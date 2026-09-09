import AppKit
import Foundation

// Generates an AppIcon.iconset (PNGs) for MacDock.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makeIcon(pixel: Int) -> NSImage {
    let s = CGFloat(pixel)
    return NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let r = NSRect(origin: .zero, size: rect.size)
        let inset = r.insetBy(dx: r.width * 0.05, dy: r.height * 0.05)
        let path = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.23, yRadius: inset.height * 0.23)
        if let grad = NSGradient(colors: [
            NSColor(calibratedRed: 0.30, green: 0.58, blue: 0.97, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.50, alpha: 1),
        ]) { grad.draw(in: path, angle: -70) }
        // dock-like translucent bar
        let bar = NSBezierPath(roundedRect: inset.insetBy(dx: inset.width * 0.08, dy: inset.height * 0.30),
                               xRadius: inset.width * 0.12, yRadius: inset.height * 0.12)
        NSColor(white: 1, alpha: 0.85).setFill()
        bar.fill()
        // three "icons"
        NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.95, alpha: 1).setFill()
        let bw = inset.width * 0.14
        for i in 0..<3 {
            let x = inset.minX + inset.width * (0.20 + CGFloat(i) * 0.24)
            let y = inset.minY + inset.height * 0.34
            NSRect(x: x, y: y, width: bw, height: inset.height * 0.16).fill()
        }
        return true
    }
}

let spec: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (base, scale) in spec {
    let image = makeIcon(pixel: base * scale)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? png.write(to: url)
}
print("iconset written: \(outDir)")
