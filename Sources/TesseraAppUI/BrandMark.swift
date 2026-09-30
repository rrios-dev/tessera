import AppKit

/// Tessera's mark — three tiles whose gaps draw a T — drawn for the menu bar as a template
/// image, so macOS tints it for light and dark menu bars. Geometry: assets/brand/generate.py.
@MainActor
enum BrandMark {
    /// The tiles on the mark's 56-unit grid (the 100-unit grid minus its 22-unit margin).
    static let tiles: [NSRect] = [
        NSRect(x: 0, y: 0, width: 56, height: 17),
        NSRect(x: 0, y: 23, width: 25, height: 33),
        NSRect(x: 31, y: 23, width: 25, height: 33),
    ]

    /// - Parameter outlined: tiles drawn as outlines (Tessera paused).
    static func image(pointSize: CGFloat = 16, outlined: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { bounds in
            let inset: CGFloat = pointSize * 0.06
            let scale = (bounds.width - inset * 2) / 56
            NSColor.black.set()
            for tile in tiles {
                let rect = NSRect(x: inset + tile.minX * scale, y: inset + tile.minY * scale, width: tile.width * scale, height: tile.height * scale)
                let radius = max(0.8, 2 * scale)
                if outlined {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
                    path.lineWidth = 1.2
                    path.stroke()
                } else {
                    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tessera"
        return image
    }
}
