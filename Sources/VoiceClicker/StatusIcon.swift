import AppKit

/// Draws the menu bar icon.
enum StatusIcon {
    /// Every state is drawn on this canvas so the icon never changes size.
    static let size = NSSize(width: 22, height: 18)

    /// The menu bar image, with a small red dot while the mic is recording.
    static func image(_ symbol: String, listeningDot: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = (NSImage(systemSymbolName: symbol, accessibilityDescription: "Voice Clicker")
            ?? NSImage(systemSymbolName: "av.remote", accessibilityDescription: "Voice Clicker"))?
            .withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: (rect.width - base.size.width) / 2, y: (rect.height - base.size.height) / 2,
                                   width: base.size.width, height: base.size.height)
            guard listeningDot else {
                base.draw(in: glyphRect)
                return true
            }
            // A template image can't carry colour, so tint the glyph to the
            // menu bar's text colour ourselves and add the red dot.
            let glyph = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: glyphRect)
            let d: CGFloat = 7
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)).fill()
            return true
        }
        image.isTemplate = !listeningDot
        image.accessibilityDescription = "Voice Clicker"
        return image
    }
}
