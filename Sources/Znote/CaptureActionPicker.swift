import AppKit

/// Small floating panel shown after the user finishes selecting a region.
/// Lets them pick: 📷 capture an image, 🎥 record video, or cancel.
final class CaptureActionPicker {
    private var panel: NSPanel?
    private var localKeyMonitor: Any?

    private var onCapture: (() -> Void)?
    private var onRecord: (() -> Void)?
    private var onCancel: (() -> Void)?

    /// Show the picker positioned near (below, or above if no room) the given
    /// selection rect. `selectionRect` is in NSScreen / window coordinates
    /// (bottom-left origin), the same coord system RegionSelector returns.
    func show(near selectionRect: NSRect,
              onCapture: @escaping () -> Void,
              onRecord: @escaping () -> Void,
              onCancel: @escaping () -> Void) {
        if panel != nil { return }

        self.onCapture = onCapture
        self.onRecord = onRecord
        self.onCancel = onCancel

        let w: CGFloat = 220
        let h: CGFloat = 66       // 52 for buttons + 14 for keyboard hint row
        let gap: CGFloat = 12

        // Prefer below the selection; flip above if no room.
        var origin = NSPoint(
            x: selectionRect.midX - w / 2,
            y: selectionRect.minY - h - gap
        )
        if let screen = NSScreen.main {
            if origin.y < screen.frame.minY + 8 {
                origin.y = selectionRect.maxY + gap
            }
            // Keep horizontally on-screen
            origin.x = max(screen.frame.minX + 8, min(origin.x, screen.frame.maxX - w - 8))
        }

        let p = PickerPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = buildContent(width: w, height: h)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Keyboard shortcuts:
        //   Return / Enter → Capture (default / primary action)
        //   R              → Record
        //   ESC            → Cancel
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 36, 76:        // Return, numpad Enter
                self?.handleCapture()
                return nil
            case 15:            // R
                self?.handleRecord()
                return nil
            case 53:            // ESC
                self?.handleCancel()
                return nil
            default:
                return event
            }
        }
        self.panel = p
        log("CaptureActionPicker: shown at \(origin)")
    }

    func dismiss() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        onCapture = nil
        onRecord = nil
        onCancel = nil
    }

    // MARK: - Button handlers

    fileprivate func handleCapture() {
        let cb = onCapture; dismiss(); cb?()
    }
    fileprivate func handleRecord() {
        let cb = onRecord; dismiss(); cb?()
    }
    fileprivate func handleCancel() {
        let cb = onCancel; dismiss(); cb?()
    }

    // MARK: - UI

    private func buildContent(width: CGFloat, height: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        root.layer?.cornerRadius = 12
        root.layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        root.layer?.borderWidth = 1
        root.appearance = NSAppearance(named: .darkAqua)

        // Button row sits in the top portion; hint row is the bottom 14px
        // (4px top pad, 10pt text). NSView coords are bottom-left origin, so
        // buttons get a higher y than hints.
        let btnY: CGFloat = 22
        let hintY: CGFloat = 4

        let captureBtn = PickerButton(symbol: "camera.fill", title: "Capture", accent: true)
        captureBtn.frame = NSRect(x: 8, y: btnY, width: 92, height: 36)
        captureBtn.onClick = { [weak self] in self?.handleCapture() }
        root.addSubview(captureBtn)

        let recordBtn = PickerButton(symbol: "video.fill", title: "Record", accent: false)
        recordBtn.frame = NSRect(x: 104, y: btnY, width: 78, height: 36)
        recordBtn.onClick = { [weak self] in self?.handleRecord() }
        root.addSubview(recordBtn)

        let cancelBtn = PickerButton(symbol: "xmark", title: nil, accent: false, destructive: true)
        cancelBtn.frame = NSRect(x: 186, y: btnY, width: 28, height: 36)
        cancelBtn.onClick = { [weak self] in self?.handleCancel() }
        root.addSubview(cancelBtn)

        // Keyboard hint row — small muted glyphs centered under each button.
        // Enter uses ↵ (Unicode 'Return Symbol'), Record uses the letter R,
        // Cancel uses 'esc'.
        addHint("↵", under: captureBtn.frame, in: root, y: hintY)
        addHint("R", under: recordBtn.frame, in: root, y: hintY)
        addHint("esc", under: cancelBtn.frame, in: root, y: hintY)

        return root
    }

    /// Draws a tiny shortcut-key glyph centered horizontally under a button.
    private func addHint(_ text: String, under btnFrame: NSRect, in root: NSView, y: CGFloat) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor(white: 0.55, alpha: 1.0)
        label.alignment = .center
        label.drawsBackground = false
        label.isBordered = false
        label.frame = NSRect(x: btnFrame.minX, y: y, width: btnFrame.width, height: 14)
        root.addSubview(label)
    }
}

private final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Dark-themed button with SF Symbol + optional text label. `accent: true`
/// fills with the app's blue; `destructive: true` tints the icon red.
private final class PickerButton: NSView {
    private let symbol: String
    private let title: String?
    private let accent: Bool
    private let destructive: Bool
    private var hovered = false
    private var pressed = false

    var onClick: (() -> Void)?

    init(symbol: String, title: String?, accent: Bool = false, destructive: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.accent = accent
        self.destructive = destructive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = false
        addTrackingArea()
        updateBackground()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func addTrackingArea() {
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; updateBackground() }
    override func mouseDown(with event: NSEvent) { pressed = true; updateBackground() }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        updateBackground()
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
    }

    private func updateBackground() {
        let bg: NSColor
        if accent {
            bg = NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: pressed ? 1.0 : (hovered ? 0.95 : 0.85))
        } else {
            let v: CGFloat = pressed ? 0.32 : (hovered ? 0.24 : 0.18)
            bg = NSColor(white: v, alpha: 1.0)
        }
        layer?.backgroundColor = bg.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let symbolColor: NSColor = destructive
            ? NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1.0)
            : .white
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let baseImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let img = baseImg.withSymbolConfiguration(config) ?? baseImg

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]

        if let title = title {
            // Icon + text, both centered vertically. Icon left, then 6px gap, then text.
            let textSize = (title as NSString).size(withAttributes: textAttrs)
            let totalW = img.size.width + 6 + textSize.width
            let startX = (bounds.width - totalW) / 2
            let iconRect = NSRect(
                x: startX,
                y: (bounds.height - img.size.height) / 2,
                width: img.size.width,
                height: img.size.height
            )
            img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            // Tint the symbol: re-draw with source-in to color it
            symbolColor.set()
            iconRect.fill(using: .sourceAtop)

            (title as NSString).draw(
                at: NSPoint(x: startX + img.size.width + 6,
                            y: (bounds.height - textSize.height) / 2),
                withAttributes: textAttrs
            )
        } else {
            // Icon only, centered.
            let iconRect = NSRect(
                x: (bounds.width - img.size.width) / 2,
                y: (bounds.height - img.size.height) / 2,
                width: img.size.width,
                height: img.size.height
            )
            img.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            symbolColor.set()
            iconRect.fill(using: .sourceAtop)
        }
    }
}
