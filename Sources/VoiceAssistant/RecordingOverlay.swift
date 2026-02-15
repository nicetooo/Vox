import AppKit
import Foundation

/// Floating overlay window that shows a waveform animation during recording.
class RecordingOverlay {
    private var window: NSPanel?
    private var waveformView: WaveformView?
    private var audioLevel: Float = 0.0

    func show() {
        guard window == nil else { return }

        let width: CGFloat = 220
        let height: CGFloat = 56

        // Create the waveform view
        let waveform = WaveformView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        self.waveformView = waveform

        // Dark background container
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        // No border
        container.layer?.borderWidth = 0
        container.addSubview(waveform)

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
        panel.contentView = container

        // Position at bottom center of main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - width / 2
            let y = screenFrame.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.window = panel

        startAnimation()
    }

    func hide() {
        stopAnimation()
        window?.orderOut(nil)
        window = nil
        waveformView = nil
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
