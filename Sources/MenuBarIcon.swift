import AppKit

/// The menu bar icon: the app icon's three offset cards as a template image, so macOS
/// colours it for light and dark menu bars. A thin gap around each card keeps the layers
/// crisp at this size, and the front card's two lines are cut out of it.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 17), flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            let card = NSSize(width: 12.6, height: 10.2)
            let radius: CGFloat = 2.6
            // Back to front, as in the app icon: up and to the right, down and to the left.
            let origins = [NSPoint(x: 5.8, y: 0.6), NSPoint(x: 3.2, y: 3.6), NSPoint(x: 0.6, y: 6.6)]
            let alphas: [CGFloat] = [0.45, 0.7, 1]

            for (index, origin) in origins.enumerated() {
                let rect = NSRect(origin: origin, size: card)
                if index > 0 {
                    // Clear a thin gap around this card so it stands apart from the one behind.
                    context.compositingOperation = .clear
                    NSBezierPath(roundedRect: rect.insetBy(dx: -1.1, dy: -1.1), xRadius: radius + 1.1, yRadius: radius + 1.1).fill()
                }
                context.compositingOperation = .sourceOver
                NSColor.black.withAlphaComponent(alphas[index]).setFill()
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            }

            // The two lines on the front card.
            context.compositingOperation = .clear
            let front = origins[2]
            NSBezierPath(roundedRect: NSRect(x: front.x + 2.2, y: front.y + 3, width: 6.6, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()
            NSBezierPath(roundedRect: NSRect(x: front.x + 2.2, y: front.y + 5.6, width: 4.6, height: 1.3), xRadius: 0.65, yRadius: 0.65).fill()
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Dropod"
        return image
    }()
}
