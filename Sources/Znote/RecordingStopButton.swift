import AppKit
import QuartzCore

/// Floating pill in the top-right of the screen during recording, showing a
/// pulsing red dot, elapsed time, and a stop button. Clicking the stop button
/// (or pressing ESC anywhere) fires `onStop`.
final class RecordingStopButton {
    private var panel: NSPanel?
    private var elapsedLabel: NSTextField?
    private var timer: Timer?
    private var startedAt: Date?
    private var escMonitor: Any?

    private var onStop: (() -> Void)?

    /// Show the floating control. Caller owns "stop" behavior.
    func show(onStop: @escaping () -> Void) {
        if panel != nil { return }
        self.onStop = onStop
        self.startedAt = Date()

        guard let screen = NSScreen.main else { return }
        let w: CGFloat = 150
        let h: CGFloat = 38
        let margin: CGFloat = 16
        // Tucked under the menu bar, top-right.
        let origin = NSPoint(
            x: screen.frame.maxX - w - margin,
            y: screen.frame.maxY - h - 40
        )

        let p = StopPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = false
        p.isMovableByWindowBackground = true
        p.contentView = buildContent(w: w, h: h)
        p.orderFront(nil)
        self.panel = p

        // Tick once per second
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.startedAt else { return }
            let elapsed = Int(Date().timeIntervalSince(started))
            self.elapsedLabel?.stringValue = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }

        // ESC stops recording too (matches the "press ESC to cancel" pattern
        // used elsewhere in the app).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.triggerStop()
                return nil
            }
            return event
        }

        log("RecordingStopButton: shown")
    }

    func hide() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil
        startedAt = nil
        onStop = nil
        elapsedLabel = nil
    }

    fileprivate func triggerStop() {
        let cb = onStop
        hide()
        cb?()
    }

    // MARK: - UI

    private func buildContent(w: CGFloat, h: CGFloat) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.55).cgColor
        root.appearance = NSAppearance(named: .darkAqua)

        // Pulsing red dot (recording indicator)
        let dotSize: CGFloat = 8
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(red: 1.0, green: 0.25, blue: 0.25, alpha: 1.0).cgColor
        dot.layer?.cornerRadius = dotSize / 2
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
        root.addSubview(dot)

        // Elapsed time label
        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        elapsed.textColor = .white
        elapsed.alignment = .left
        elapsed.translatesAutoresizingMaskIntoConstraints = false
        elapsed.isEditable = false
        elapsed.isBordered = false
        elapsed.drawsBackground = false
        self.elapsedLabel = elapsed
        root.addSubview(elapsed)

        // Stop button
        let stopSize: CGFloat = 24
        let stopBtn = StopButtonView()
        stopBtn.translatesAutoresizingMaskIntoConstraints = false
        stopBtn.onClick = { [weak self] in self?.triggerStop() }
        root.addSubview(stopBtn)

        // All three elements share root.centerYAnchor so they line up regardless
        // of NSTextField's quirky intrinsic vertical-baseline behavior.
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),
            dot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            elapsed.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            elapsed.centerYAnchor.constraint(equalTo: root.centerYAnchor),

            stopBtn.widthAnchor.constraint(equalToConstant: stopSize),
            stopBtn.heightAnchor.constraint(equalToConstant: stopSize),
            stopBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stopBtn.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        return root
    }
}

private final class StopPanel: NSPanel {
    // We don't need keyboard focus on the panel itself — ESC is captured by
    // the local monitor in RecordingStopButton. Refusing key prevents the
    // panel from stealing focus from whatever the user is recording.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StopButtonView: NSView {
    var onClick: (() -> Void)?
    private var hovered = false
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        updateBg()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateBg() {
        let r: CGFloat = pressed ? 0.78 : (hovered ? 0.95 : 0.82)
        layer?.backgroundColor = NSColor(red: r, green: 0.22, blue: 0.22, alpha: 1.0).cgColor
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateBg() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false; updateBg() }
    override func mouseDown(with event: NSEvent) { pressed = true; updateBg() }
    override func mouseUp(with event: NSEvent) {
        pressed = false; updateBg()
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // White rounded square in the middle = "stop"
        NSColor.white.setFill()
        let inset: CGFloat = 7
        NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                     xRadius: 2, yRadius: 2).fill()
    }
}
