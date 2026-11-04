import AppKit

/// Draws the menu bar icon.
enum StatusIcon {
    /// Every state is drawn on this canvas so the icon never changes size.
    static let size = NSSize(width: 22, height: 18)

    /// The menu bar image. A red dot at the top right while the mic is
    /// recording, and a blue dot at the bottom right while the Spotlight is
    /// connected to this Mac over Bluetooth (rather than through the relay).
    static func image(_ symbol: String, listeningDot: Bool, bluetoothDot: Bool = false) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = (NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Clicker")
            ?? NSImage(systemSymbolName: "av.remote", accessibilityDescription: "Voice Clicker"))?
            .withSymbolConfiguration(config) else { return nil }
        let hasDot = listeningDot || bluetoothDot
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2,
                                   width: base.size.width, height: base.size.height)
            guard hasDot else {
                base.draw(in: glyphRect)
                return true
            }
            // A template image can't carry colour, so tint the glyph to the
            // menu bar's text colour ourselves and add the dots.
            let glyph = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: glyphRect)
            let d: CGFloat = 7
            if listeningDot {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)).fill()
            }
            if bluetoothDot {
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - d, y: 0, width: d, height: d)).fill()
            }
            return true
        }
        image.isTemplate = !hasDot
        image.accessibilityDescription = "Voice Clicker"
        return image
    }
}
