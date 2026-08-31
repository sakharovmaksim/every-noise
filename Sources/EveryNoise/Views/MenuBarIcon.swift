import AppKit

/// Геометрия повторяет `scripts/make-icon.swift` — правьте оба места.
enum MenuBarIcon {
    private static let size = NSSize(width: 19, height: 16)

    static func wave(active: Bool) -> NSImage {
        active ? activeImage : idleImage
    }

    private static let activeImage = makeWave(alpha: 1)
    private static let idleImage = makeWave(alpha: 0.35)

    private static func makeWave(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath()
            let left = rect.minX + 1
            let right = rect.maxX - 1
            let midY = rect.midY
            let amplitude = rect.height * 0.30
            let steps = 140
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let x = left + (right - left) * t
                let taper = sin(.pi * t)
                let y = midY + sin(t * .pi * 4) * amplitude * (0.35 + 0.65 * taper)
                if step == 0 {
                    path.move(to: NSPoint(x: x, y: y))
                } else {
                    path.line(to: NSPoint(x: x, y: y))
                }
            }
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
