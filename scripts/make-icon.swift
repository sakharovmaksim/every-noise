// App icon generator. Usage: xcrun swift scripts/make-icon.swift <path to .icns>
import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Resources/AppIcon.icns")

func render(size: Int) -> Data {
    let side = CGFloat(size)
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    guard let context = NSGraphicsContext.current else { fatalError("no graphics context") }
    context.imageInterpolation = .high

    let inset = side * 0.09
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.225
    let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.32, alpha: 1),
            NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.62, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.78, blue: 0.70, alpha: 1),
        ],
        atLocations: [0, 0.55, 1],
        colorSpace: .deviceRGB
    )
    gradient?.draw(in: plate, angle: -60)

    let wave = NSBezierPath()
    let amplitude = rect.height * 0.17
    let midY = rect.midY
    let left = rect.minX + rect.width * 0.14
    let right = rect.maxX - rect.width * 0.14
    let steps = 220
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let x = left + (right - left) * t
        let taper = sin(CGFloat.pi * t)
        let y = midY + sin(t * .pi * 4) * amplitude * (0.35 + 0.65 * taper)
        if step == 0 { wave.move(to: NSPoint(x: x, y: y)) } else { wave.line(to: NSPoint(x: x, y: y)) }
    }
    wave.lineWidth = max(1, rect.width * 0.055)
    wave.lineCapStyle = .round
    wave.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.95).setStroke()
    wave.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("could not render size \(size)")
    }
    return png
}

let workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EveryNoise.iconset")
try? FileManager.default.removeItem(at: workDir)
try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

let variants: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    try render(size: variant.size).write(to: workDir.appendingPathComponent(variant.name))
}

try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", workDir.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
try? FileManager.default.removeItem(at: workDir)
print("Icon built: \(output.path)")
