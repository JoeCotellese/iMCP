// ABOUTME: Builds the Pontemac menu bar status item image from the point.3 SF Symbol.
// ABOUTME: Bakes the disabled dimming into a template image so the status bar cannot drop it.

import AppKit

enum MenuBarIcon {
    static let symbolName = "point.3.connected.trianglepath.dotted"
    static let accessibilityLabel = "Pontemac"
    static let disabledOpacity: CGFloat = 0.25

    static func image(isEnabled: Bool) -> NSImage {
        guard
            let symbol = NSImage(
                systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        else {
            return NSImage()
        }
        let image = isEnabled ? symbol : dimmed(symbol)
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel
        return image
    }

    private static func dimmed(_ symbol: NSImage) -> NSImage {
        NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: disabledOpacity)
            return true
        }
    }
}
