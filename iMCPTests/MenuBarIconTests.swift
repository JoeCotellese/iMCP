// ABOUTME: Unit tests for MenuBarIcon, the SF Symbol status item image for Pontemac (#46).
// ABOUTME: Pins the symbol name and the rendered alpha of the enabled and disabled states.

import AppKit
import Testing

@Suite struct MenuBarIconTests {
    @Test func testSymbolNameResolves() throws {
        #expect(MenuBarIcon.symbolName == "point.3.connected.trianglepath.dotted")
        #expect(NSImage(systemSymbolName: MenuBarIcon.symbolName, accessibilityDescription: nil) != nil)
    }

    @Test func testEnabledImageIsFullStrengthTemplate() throws {
        let image = MenuBarIcon.image(isEnabled: true)
        #expect(image.isTemplate)
        #expect(maxAlpha(of: image) >= 0.95)
    }

    @Test func testDisabledImageIsDimmedTemplate() throws {
        let image = MenuBarIcon.image(isEnabled: false)
        #expect(image.isTemplate)
        #expect((0.20...0.30).contains(maxAlpha(of: image)))
    }

    @Test func testImageIsLabeledPontemac() throws {
        #expect(MenuBarIcon.image(isEnabled: true).accessibilityDescription == "Pontemac")
        #expect(MenuBarIcon.image(isEnabled: false).accessibilityDescription == "Pontemac")
    }

    private func maxAlpha(of image: NSImage) -> CGFloat {
        let side = 64
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var result: CGFloat = 0
        for x in 0..<side {
            for y in 0..<side {
                result = max(result, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return result
    }
}
