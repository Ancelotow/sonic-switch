import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 220, yRadius: 220)
        NSGradient(starting: NSColor(red: 0.08, green: 0.19, blue: 0.24, alpha: 1),
                   ending: NSColor(red: 0.03, green: 0.38, blue: 0.42, alpha: 1))!.draw(in: background, angle: 50)
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: 512, y: 802))
        shield.line(to: NSPoint(x: 758, y: 710))
        shield.line(to: NSPoint(x: 735, y: 475))
        shield.curve(to: NSPoint(x: 512, y: 230), controlPoint1: NSPoint(x: 720, y: 355), controlPoint2: NSPoint(x: 580, y: 260))
        shield.curve(to: NSPoint(x: 289, y: 475), controlPoint1: NSPoint(x: 444, y: 260), controlPoint2: NSPoint(x: 304, y: 355))
        shield.line(to: NSPoint(x: 266, y: 710))
        shield.close()
        NSColor(red: 0.24, green: 0.87, blue: 0.76, alpha: 1).setStroke()
        shield.lineWidth = 38
        shield.lineJoinStyle = .round
        shield.stroke()
        let arrows = NSBezierPath()
        arrows.lineWidth = 38
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.move(to: NSPoint(x: 385, y: 590))
        arrows.line(to: NSPoint(x: 641, y: 590))
        arrows.move(to: NSPoint(x: 584, y: 647))
        arrows.line(to: NSPoint(x: 641, y: 590))
        arrows.line(to: NSPoint(x: 584, y: 533))
        arrows.move(to: NSPoint(x: 639, y: 452))
        arrows.line(to: NSPoint(x: 383, y: 452))
        arrows.move(to: NSPoint(x: 440, y: 509))
        arrows.line(to: NSPoint(x: 383, y: 452))
        arrows.line(to: NSPoint(x: 440, y: 395))
        NSColor.white.setStroke()
        arrows.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", directory.path, "-o", destination.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("Échec de création de l’icône") }
