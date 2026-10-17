import AppKit
import MagpieLiteCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        // The application holds its delegate weakly.
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = Self.makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.glyph()
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("Magpie Lite")
        }
        statusItem = item
    }

    /// An `.accessory` app draws no menu bar, but key equivalents still route through the main menu.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Magpie Lite",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        return main
    }

    /// The app glyph: three rising rounded bars, as a template image.
    private static func glyph() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let barWidth: CGFloat = 4
            let gap: CGFloat = 2
            let heights: [CGFloat] = [7, 11, 15]
            let originX = (size.width - (3 * barWidth + 2 * gap)) / 2
            let baseline: CGFloat = 1.5
            NSColor.black.setFill()
            for (index, height) in heights.enumerated() {
                let rect = NSRect(
                    x: originX + CGFloat(index) * (barWidth + gap),
                    y: baseline,
                    width: barWidth,
                    height: height
                )
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
