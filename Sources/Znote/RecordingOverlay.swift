import AppKit
import Foundation

/// Floating overlay window that shows a waveform animation during recording.
class RecordingOverlay {
    private var window: NSPanel?
    private var waveformView: WaveformView?
    private var audioLevel: Float = 0.0

    private var messageLabel: NSTextField?
    private var hintLabel: NSTextField?

    /// Show the waveform. `hint` is an optional small label (e.g. "→ English")
    /// shown above the waveform — used to indicate Whisper's translate mode.
    func show(hint: String? = nil) {
        showOverlay(mode: .recording(hint: hint))
    }

    /// Show a text message (e.g. "Loading model...") instead of waveform
    func showMessage(_ text: String) {
        showOverlay(mode: .message(text))
    }

    private enum OverlayMode {
        case recording(hint: String?)
        case message(String)
    }

    private func showOverlay(mode: OverlayMode) {
        // If already showing, just update content
        if let window = window {
            switch mode {
            case .recording(let hint):
                messageLabel?.isHidden = true
                waveformView?.isHidden = false
                applyHint(hint)
                startAnimation()
            case .message(let text):
                stopAnimation()
                waveformView?.isHidden = true
                hintLabel?.isHidden = true
                if let label = messageLabel {
                    label.stringValue = text
                    label.isHidden = false
                }
            }
            window.orderFront(nil)
            return
        }

        let innerWidth: CGFloat = 280
        let innerHeight: CGFloat = 56
        let cornerRadius: CGFloat = 14
        // Padding around the inner container so the glow can fully fade out
        // before hitting the NSPanel's hard edge. Must be ≥ ~2.5× outer
        // shadowRadius or you'll see a rectangular cut-off where the shadow
        // meets the panel. We stack two shadow layers (see below), so this
        // needs to accommodate the widest one.
        let glowPad: CGFloat = 70
        let width = innerWidth + glowPad * 2
        let height = innerHeight + glowPad * 2
        let shadowPath = CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: innerWidth, height: innerHeight),
            cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        )

        // Create the waveform view
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: innerWidth, height: innerHeight))
        self.waveformView = waveform

        // Create message label (for loading states) — vertically + horizontally centered
        let label = NSTextField(labelWithString: "")
        let labelHeight: CGFloat = 20
        label.frame = NSRect(x: 16, y: (innerHeight - labelHeight) / 2, width: innerWidth - 32, height: labelHeight)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.85, alpha: 1.0)
        label.isHidden = true
        self.messageLabel = label

        // Hint label — small text shown top-right corner of the inner container
        // ("→ English" in translate mode). Hidden by default.
        let hint = NSTextField(labelWithString: "")
        let hintHeight: CGFloat = 14
        hint.frame = NSRect(x: innerWidth - 100, y: innerHeight - hintHeight - 4,
                            width: 96, height: hintHeight)
        hint.alignment = .right
        hint.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        hint.textColor = NSColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 1.0)
        hint.isHidden = true
        self.hintLabel = hint

        let glowColor = NSColor(red: 0.55, green: 0.80, blue: 1.0, alpha: 1.0).cgColor

        // Outer diffuse halo: wide soft glow. Its large radius spreads light
        // far enough that the per-corner density drop becomes imperceptible,
        // which visually fills the "notch" at the four corners of the inner
        // glow. Layer is fully transparent — the explicit shadowPath alone is
        // enough to generate the shadow.
        let halo = NSView(frame: NSRect(x: glowPad, y: glowPad, width: innerWidth, height: innerHeight))
        halo.wantsLayer = true
        halo.layer?.backgroundColor = NSColor.clear.cgColor
        halo.layer?.masksToBounds = false
        halo.layer?.shadowColor = glowColor
        halo.layer?.shadowOpacity = 0.45
        halo.layer?.shadowRadius = 28
        halo.layer?.shadowOffset = .zero
        halo.layer?.shadowPath = shadowPath

        // Inner dark container with hairline border + tight rim glow.
        // masksToBounds must be false so the layer shadow is visible.
        let container = NSView(frame: NSRect(x: glowPad, y: glowPad, width: innerWidth, height: innerHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = false
        container.layer?.borderWidth = 1.0
        container.layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        container.layer?.shadowColor = glowColor
        container.layer?.shadowOpacity = 0.55
        container.layer?.shadowRadius = 10
        container.layer?.shadowOffset = .zero
        // Explicit shadowPath — without this CALayer infers shadow from alpha
        // mask and corners look discontinuous.
        container.layer?.shadowPath = shadowPath
        container.addSubview(waveform)
        container.addSubview(label)
        container.addSubview(hint)

        // Outer transparent host: halo goes first (behind), container on top.
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        outer.addSubview(halo)
        outer.addSubview(container)

        // Create floating panel — completely borderless
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = outer

        // Position at bottom center of main screen — shift by glowPad so the
        // *visual* container sits where the old overlay did.
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 80 - glowPad
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.window = panel

        switch mode {
        case .recording(let hintText):
            messageLabel?.isHidden = true
            waveformView?.isHidden = false
            applyHint(hintText)
            startAnimation()
        case .message(let text):
            waveformView?.isHidden = true
            hintLabel?.isHidden = true
            label.stringValue = text
            label.isHidden = false
        }
    }

    private func applyHint(_ text: String?) {
        guard let label = hintLabel else { return }
        if let text = text, !text.isEmpty {
            label.stringValue = text
            label.isHidden = false
        } else {
            label.isHidden = true
        }
    }

    func hide() {
        stopAnimation()
        window?.orderOut(nil)
        window = nil
        waveformView = nil
        hintLabel = nil
    }

    /// Update with current audio level (0.0 to 1.0)
    func updateLevel(_ level: Float) {
        self.audioLevel = level
    }

    private var animationTimer: Timer?

    private func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.waveformView?.audioLevel = self.audioLevel
            self.waveformView?.needsDisplay = true
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }
}

// MARK: - Waveform View

/// Custom view that draws animated sound wave bars with a dark theme.
class WaveformView: NSView {
    var audioLevel: Float = 0.0

    private let barCount = 32
    private let barSpacing: CGFloat = 1.5
    private var barHeights: [CGFloat]
    private var targetHeights: [CGFloat]
    private let smoothing: CGFloat = 0.25

    override init(frame: NSRect) {
        barHeights = Array(repeating: 2.0, count: 32)
        targetHeights = Array(repeating: 2.0, count: 32)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        barHeights = Array(repeating: 2.0, count: 32)
        targetHeights = Array(repeating: 2.0, count: 32)
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let maxBarHeight = bounds.height - 14
        let totalBarWidth = (bounds.width - 32) / CGFloat(barCount)
        let barWidth = totalBarWidth - barSpacing
        let startX: CGFloat = 16
        let centerY = bounds.height / 2

        // Update target heights based on audio level
        let level = CGFloat(min(max(audioLevel, 0.0), 1.0))
        for i in 0..<barCount {
            let centerDistance = abs(CGFloat(i) - CGFloat(barCount) / 2.0) / (CGFloat(barCount) / 2.0)
            let baseHeight: CGFloat = 2.5
            let randomVariation = CGFloat.random(in: 0.5...1.0)
            let waveShape = 1.0 - centerDistance * 0.4

            targetHeights[i] = baseHeight + (maxBarHeight * level * waveShape * randomVariation)
        }

        // Smooth animation
        for i in 0..<barCount {
            barHeights[i] += (targetHeights[i] - barHeights[i]) * smoothing
        }

        // Draw bars — black/grey premium style
        for i in 0..<barCount {
            let x = startX + CGFloat(i) * totalBarWidth
            let height = max(barHeights[i], 1.5)
            let y = centerY - height / 2

            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            // Grey to white — subtle, premium feel
            let white: CGFloat = 0.35 + (level * 0.55)
            let color = NSColor(white: white, alpha: 0.9)
            context.setFillColor(color.cgColor)
            path.fill()
        }
    }
}
