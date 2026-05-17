import AppKit
import Foundation

// MARK: - Translation Overlay

/// Floating overlay that shows a loading animation immediately, then translation results.
/// Dismiss with click-outside, Escape, or Right Option tap again.
class TranslationOverlay: NSObject {
    private var panel: NSPanel?
    private var loadingView: LoadingDotsView?
    private var globalClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var translatedText: String = ""
    private var dismissed = false
    private var savedTopCenter: NSPoint?  // Save position so result appears in same spot

    var isShowing: Bool { panel != nil }

    // MARK: - Show Loading (call immediately on Right ⌥ tap)

    func showLoading() {
        hide()
        dismissed = false

        let width: CGFloat = 120
        let height: CGFloat = 48

        // Loading dots animation
        let dots = LoadingDotsView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.loadingView = dots

        // Container
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.addSubview(dots)

        // Panel
        let p = makePanel(width: width, height: height)
        p.contentView = container

        // Position near mouse and save anchor point
        let mouse = NSEvent.mouseLocation
        positionPanel(p, nearMouse: mouse)
        savedTopCenter = NSPoint(
            x: p.frame.midX,
            y: p.frame.maxY
        )

        p.orderFront(nil)
        self.panel = p
        dots.startAnimating()

        setupMonitors()
        log("TranslationOverlay: loading shown")
    }

    // MARK: - Show Result (replaces loading with translation + copy button)

    func showResult(_ text: String) {
        // If user dismissed while waiting, don't show result
        guard !dismissed else {
            log("TranslationOverlay: dismissed before result arrived, ignoring")
            return
        }

        loadingView?.stopAnimating()
        loadingView = nil
        self.translatedText = text

        let padding: CGFloat = 16
        let maxTextWidth: CGFloat = 360
        let minPanelWidth: CGFloat = 160
        let btnHeight: CGFloat = 28
        let btnWidth: CGFloat = 76

        // --- Translated text ---
        let textField = NSTextField(wrappingLabelWithString: text)
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.textColor = .white
        textField.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        textField.preferredMaxLayoutWidth = maxTextWidth
        textField.lineBreakMode = .byWordWrapping
        let textSize = textField.fittingSize

        // --- Copy button ---
        let copyBtn = PillButton(title: L("translation.copy"))
        copyBtn.onClick = { [weak self] in self?.doCopy(button: copyBtn) }

        // --- Calculate panel size ---
        let panelWidth = max(min(textSize.width + padding * 2 + 4, maxTextWidth + padding * 2), minPanelWidth)
        let panelHeight = textSize.height + btnHeight + padding * 2.5

        // --- Container ---
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        // Layout (macOS: 0,0 = bottom-left)
        let btnY: CGFloat = padding * 0.6
        let textY = btnY + btnHeight + padding * 0.4
        textField.frame = NSRect(x: padding, y: textY, width: panelWidth - padding * 2, height: textSize.height)
        copyBtn.frame = NSRect(x: panelWidth - btnWidth - padding, y: btnY, width: btnWidth, height: btnHeight)

        container.addSubview(textField)
        container.addSubview(copyBtn)

        // Remove old panel, build new one
        removeMonitors()
        panel?.orderOut(nil)

        let p = makePanel(width: panelWidth, height: panelHeight)
        p.contentView = container

        // Position: keep top-center aligned with loading panel's position
        if let anchor = savedTopCenter {
            let x = anchor.x - panelWidth / 2
            let y = anchor.y - panelHeight
            p.setFrameOrigin(NSPoint(x: x, y: y))
            clampToScreen(panel: p)
        } else {
            positionPanel(p, nearMouse: NSEvent.mouseLocation)
        }

        p.orderFront(nil)
        self.panel = p

        setupMonitors()
        log("TranslationOverlay: result shown")
    }

    // MARK: - Hide

    func hide() {
        dismissed = true
        loadingView?.stopAnimating()
        loadingView = nil
        removeMonitors()
        guard panel != nil else { return }
        panel?.orderOut(nil)
        panel = nil
        log("TranslationOverlay: hidden")
    }

    // MARK: - Copy

    private func doCopy(button: PillButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
        log("TranslationOverlay: copied to clipboard")

        button.updateTitle("已复制 ✓")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.hide()
        }
    }

    // MARK: - Panel Factory

    private func makePanel(width: CGFloat, height: CGFloat) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        return p
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, nearMouse mouse: NSPoint) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return }

        var x = mouse.x + 12
        var y = mouse.y - panel.frame.height - 12

        x = min(x, sf.maxX - panel.frame.width - 8)
        x = max(x, sf.minX + 8)
        y = max(y, sf.minY + 8)
        y = min(y, sf.maxY - panel.frame.height - 8)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func clampToScreen(panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return }

        var origin = panel.frame.origin
        origin.x = min(origin.x, sf.maxX - panel.frame.width - 8)
        origin.x = max(origin.x, sf.minX + 8)
        origin.y = max(origin.y, sf.minY + 8)
        origin.y = min(origin.y, sf.maxY - panel.frame.height - 8)

        panel.setFrameOrigin(origin)
    }

    // MARK: - Dismiss Monitors

    private func setupMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }
        }
    }

    private func removeMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }
}

// MARK: - Loading Dots Animation

/// Three dots that pulse in sequence — clean loading indicator.
class LoadingDotsView: NSView {
    private var animationTimer: Timer?
    private var phase: Int = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    func startAnimating() {
        phase = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.phase += 1
            self?.needsDisplay = true
        }
    }

    func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let dotSize: CGFloat = 7
        let spacing: CGFloat = 10
        let totalWidth = dotSize * 3 + spacing * 2
        let startX = (bounds.width - totalWidth) / 2
        let centerY = bounds.height / 2

        for i in 0..<3 {
            let x = startX + CGFloat(i) * (dotSize + spacing)
            let isActive = (i == phase % 3)
            let white: CGFloat = isActive ? 0.85 : 0.35
            let size = isActive ? dotSize + 1.5 : dotSize
            let offset = isActive ? -0.75 : 0.0

            let rect = NSRect(
                x: x + CGFloat(offset),
                y: centerY - size / 2,
                width: size,
                height: size
            )
            let path = NSBezierPath(ovalIn: rect)
            NSColor(white: white, alpha: 1.0).setFill()
            path.fill()
        }
    }
}

// MARK: - Pill Button

/// Custom clickable view that works reliably in non-activating floating panels.
class PillButton: NSView {
    private var title: String
    var onClick: (() -> Void)?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 1.0).cgColor
        layer?.cornerRadius = 8
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func updateTitle(_ newTitle: String) {
        title = newTitle
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 0.22, alpha: 1.0).cgColor
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let size = title.size(withAttributes: attrs)
        let pt = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        title.draw(at: pt, withAttributes: attrs)
    }
}
