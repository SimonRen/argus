import AppKit
import ArgusCore
import Observation

struct PopoverWarmup {
    private(set) var didWarm = false

    @discardableResult
    mutating func attempt(isReady: Bool, _ warm: () -> Bool) -> Bool {
        guard !didWarm else { return true }
        guard isReady else { return false }
        guard warm() else { return false }
        didWarm = true
        return true
    }
}

/// Owns the status item and redraws it whenever the summary, a Show-in-menubar choice or the menubar's appearance changes.
@MainActor final class StatusItemController: NSObject, NSPopoverDelegate {
    let item: NSStatusItem
    private let state: AppState
    private let preferences: MenuBarPreferences
    private var appearanceObservation: NSKeyValueObservation?
    private var activation: NSObjectProtocol?
    /// Clicks in other apps while the popover is shown.
    private var outsideClicks: Any?
    private var popover: NSPopover?
    /// Holds the hosting view in a hidden window until the popover is first shown, so AppKit/SwiftUI bridge setup is off the click path.
    private var warmWindow: NSWindow?
    private var screen: PopoverScreen?
    private var openManager: () -> Void = {}
    private var popoverWarmup = PopoverWarmup()

    init(state: AppState, preferences: MenuBarPreferences) {
        self.state = state
        self.preferences = preferences
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.render() }
            }
        }
        render()
    }

    /// One transient popover hosting `content`; with no status item window, clicks open the manager instead.
    func attach(popover content: NSViewController, screen: PopoverScreen, openManager: @escaping () -> Void) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = content
        popover.delegate = self
        self.popover = popover
        let warmWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 392, height: 600),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        warmWindow.isReleasedWhenClosed = false
        warmWindow.contentViewController = content
        warmWindow.orderOut(nil)
        warmWindow.contentView?.layoutSubtreeIfNeeded()
        self.warmWindow = warmWindow
        // Activation can land after the popover is shown; it takes key then, or it keeps the inactive look.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let popover = self?.popover, popover.isShown else { return }
                popover.contentViewController?.view.window?.makeKey()
            }
        }
        self.screen = screen
        self.openManager = openManager
    }

    @objc private func clicked() { togglePopover() }

    /// Builds the popover window once after launch, before the first status-item click.
    @discardableResult
    func prewarmPopover() -> Bool {
        guard let popover, let button = item.button else { return false }
        let warmed = popoverWarmup.attempt(isReady: button.window != nil) {
            guard !popover.isShown else { return true }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let didShow = popover.contentViewController?.view.window != nil
            popover.performClose(nil)
            return didShow
        }
        if warmed { warmWindow = nil }
        return warmed
    }

    func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button, button.window != nil else {
            openManager()
            return
        }
        // The popover's glass looks different until its window is key, which needs the app active when it opens;
        // the cooperative `activate()` can be refused here, leaving the inactive look until the first click.
        // known-ceiling: `activate(ignoringOtherApps:)` is marked to-be-deprecated → when it warns, find the replacement.
        if let frame = (button.window?.screen ?? NSScreen.main)?.visibleFrame { screen?.visibleHeight = frame.height }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // A transient popover closes on outside clicks only while the app is active; activation can be refused,
        // so a click in any other app closes it too (mouse events need no permission).
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }

    func closePopover() { popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    /// Draws the current summary and re-arms observation of everything it read.
    private func render() {
        let summary = withObservationTracking {
            MenuBarSummary.build(Tool.allCases.flatMap(state.contexts).map(state.snapshot), isShown: preferences.isShown)
        } onChange: { [weak self] in
            Task { @MainActor in self?.render() }
        }
        guard let button = item.button else { return }
        button.image = summary.showsGlyphOnly ? Self.glyph() : Self.image(summary)
        button.setAccessibilityLabel(summary.accessibilityLabel)
    }

    // MARK: - Drawing (DEC-10)

    /// `mark` is the letter fallback's box; a tool icon's box is 20 pt, so with its 10 % margin per side the glyph itself is a standard 16 pt menubar icon.
    /// The system already spaces status items apart, so the side padding is small; the tool icons carry about 10 % empty
    /// margin per side, so the icon-to-value gap and the gap between tools are drawn tighter than they read.
    private static let padding: CGFloat = 2, mark: CGFloat = 14, iconMark: CGFloat = 20, gap: CGFloat = 1, spacing: CGFloat = 5, height: CGFloat = 22
    /// The menu bar's own font (size and regular weight), with digits of equal width so values don't shift as they change.
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    private static let letterFont = NSFont.systemFont(ofSize: 8.5, weight: .heavy)
    /// An added context's name between the mark and the value.
    private static let contextFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    /// A white-silhouette tool icon filled with `color`.
    private static func tinted(_ glyph: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// A value over 85 % used, light or dark to match the menu bar.
    private static let low = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0x8A / 255, blue: 0x8A / 255, alpha: 1)
            : NSColor(srgbRed: 0xC2 / 255, green: 0x36 / 255, blue: 0x2F / 255, alpha: 1)
    }

    /// One non-template image whose colours resolve when it is drawn, in the button's own appearance, so the first frame
    /// after launch already matches the menu bar (resolving them up front drew a light-mode image until the button settled).
    static func image(_ summary: MenuBarSummary) -> NSImage {
        let label = NSColor.labelColor
        let widths = summary.segments.map { width($0.sevenDay.text) }
        let glyphs = summary.segments.map { ToolIcon.glyph($0.tool).map { tinted($0, label) } }
        let names = summary.segments.map { $0.context.map { NSAttributedString(string: $0, attributes: [.font: contextFont, .foregroundColor: NSColor.secondaryLabelColor]) } }
        // A name sits 3 pt after the mark and, with `gap`, 3 pt before the value.
        let marks = zip(glyphs, names).map { ($0 == nil ? mark : iconMark) + ($1.map { ceil($0.size().width) + 5 } ?? 0) }
        let total = padding * 2 + zip(marks, widths).reduce(0) { $0 + $1.0 + gap + $1.1 } + spacing * CGFloat(max(0, widths.count - 1))
        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x = padding
            for ((((segment, valueWidth), glyph), markWidth), name) in zip(zip(zip(zip(summary.segments, widths), glyphs), marks), names) {
                if let name {
                    let size = name.size()
                    name.draw(at: NSPoint(x: x + markWidth - 2 - size.width, y: (height - size.height) / 2))
                }
                if let glyph {
                    glyph.draw(in: NSRect(x: x, y: (height - iconMark) / 2, width: iconMark, height: iconMark))
                } else {
                    let square = NSRect(x: x + 0.75, y: (height - mark) / 2 + 0.75, width: mark - 1.5, height: mark - 1.5)
                    let path = NSBezierPath(roundedRect: square, xRadius: 4, yRadius: 4)
                    path.lineWidth = 1.5
                    label.setStroke()
                    path.stroke()
                    let letter = NSAttributedString(string: segment.letter, attributes: [.font: letterFont, .foregroundColor: label])
                    let size = letter.size()
                    letter.draw(at: NSPoint(x: x + (mark - size.width) / 2, y: (height - size.height) / 2))
                }
                x += markWidth + gap
                let value = segment.sevenDay
                let text = NSAttributedString(string: value.text, attributes: [.font: valueFont, .foregroundColor: value.severity == .low ? low : label])
                let size = text.size()
                text.draw(at: NSPoint(x: x + valueWidth - size.width, y: (height - size.height) / 2))
                x += valueWidth + spacing
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func width(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: valueFont]).size().width)
    }

    /// The app glyph: three rising rounded bars, as a template image.
    static func glyph() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let barWidth: CGFloat = 4
            let gap: CGFloat = 2
            let heights: [CGFloat] = [7, 11, 15]
            let originX = (size.width - (3 * barWidth + 2 * gap)) / 2
            let baseline: CGFloat = 1.5
            NSColor.black.setFill()
            for (index, height) in heights.enumerated() {
                let rect = NSRect(x: originX + CGFloat(index) * (barWidth + gap), y: baseline, width: barWidth, height: height)
                NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
