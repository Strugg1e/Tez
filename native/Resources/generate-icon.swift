import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for density in [1, 2] {
        let pixels = size * density
        let image = NSImage(size: NSSize(width: pixels, height: pixels), flipped: true) { _ in
            let side = CGFloat(pixels)
            NSColor(srgbRed: 0.94, green: 0.96, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: side * 0.06, y: side * 0.06,
                                           width: side * 0.88, height: side * 0.88),
                         xRadius: side * 0.2, yRadius: side * 0.2).fill()
            let transform = NSAffineTransform()
            transform.translateX(by: side * 0.18, yBy: side * 0.18)
            transform.scale(by: side * 0.64 / 40)
            transform.concat()
            NSColor(srgbRed: 0.141, green: 0.353, blue: 0.769, alpha: 1).setStroke()
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: 20, y: 20), radius: 14.5,
                           startAngle: -48, endAngle: 22, clockwise: true)
            path.move(to: NSPoint(x: 19.5, y: 13.5))
            path.line(to: NSPoint(x: 33.5, y: 13.5))
            path.move(to: NSPoint(x: 25.5, y: 13.5))
            path.line(to: NSPoint(x: 25.5, y: 26.5))
            path.lineWidth = 5.4
            path.lineCapStyle = .round
            path.stroke()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Cannot render the Tez icon")
        }
        let suffix = density == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
