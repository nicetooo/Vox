import AppKit

/// Full-screen overlay that lets the user drag out a rectangular region.
/// Returns the selected rect (in NSScreen / window coordinates, bottom-left
/// origin) via `onSelected`, or fires `onCancel` if dismissed with ESC or
/// when the dragged area is too tiny to be a real selection.
///
/// Single-display only for the first iteration; multi-display support would
/// open one window per screen and union them.
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var onSelected: ((NSRect) -> Void)?
    private var onCancel: (() -> Void)?
    private var localEscMonitor: Any?
    private var cursorPushed = false

    /// Show the selector. Calls `onSelected` once the user releases a valid
    /// rectangle (≥ 10×10 px), or `onCancel` on ESC / empty selection.
    /// One window per NSScreen so external displays get covered too.
    func begin(onSelected: @escaping (NSRect) -> Void,
               onCancel: @escaping () -> Void) {
        if !windows.isEmpty { return }

        self.onSelected = onSelected
        self.onCancel = onCancel

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            onCancel()
            return
        }

        for screen in screens {
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onComplete = { [weak self] rect in
                self?.finish(rect: rect)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }

            let panel = RegionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear        // we paint dim ourselves in the view
            panel.level = .screenSaver
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hasShadow = false
            panel.isMovable = false
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)  // ensure exact placement
            // Needed so AppKit dispatches mouse-moved / cursor-update events
            // even when our panel isn't the active app.
            panel.acceptsMouseMovedEvents = true

            panel.orderFront(nil)
            windows.append(panel)
            log("RegionSelector: window on screen \(screen.frame)")
        }

        // Make the main-display window key so it gets keyboard focus; clicking
        // any screen will then route mouse events to that screen's window.
        if let mainPanel = windows.first(where: { $0.screen == NSScreen.main }) ?? windows.first {
            mainPanel.makeKeyAndOrderFront(nil)
            if let view = mainPanel.contentView {
                mainPanel.makeFirstResponder(view)
            }
        }
        NSApp.activate(ignoringOtherApps: true)

        // ESC from anywhere cancels.
        localEscMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {  // ESC
                self?.cancel()
                return nil
            }
            return event
        }

        // Force the crosshair across the entire screen while the selector is
        // active. addCursorRect on a borderless / nonactivating panel doesn't
        // hold reliably — AppKit hands the cursor back to whoever else is under
        // the pointer the moment focus shifts. push() on the global NSCursor
        // stack overrides everything until we pop() in teardown.
        NSCursor.crosshair.push()
        cursorPushed = true
    }

    private func finish(rect: NSRect) {
        let cb = onSelected
        teardown()
        cb?(rect)
    }

    private func cancel() {
        let cb = onCancel
        teardown()
        log("RegionSelector: cancelled")
        cb?()
    }

    private func teardown() {
        if let m = localEscMonitor { NSEvent.removeMonitor(m); localEscMonitor = nil }
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        for w in windows { w.orderOut(nil) }
        windows = []
        onSelected = nil
        onCancel = nil
    }
}

/// NSPanel subclass that can become key — required for keyboard events to
/// reach the contained view (ESC handling).
private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The actual selection canvas. Draws the dim overlay, the cleared selection
/// area, the selection border, and a size readout.
private final class RegionSelectionView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var cursorTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Cursor management
    //
    // The legacy addCursorRect / resetCursorRects path is unreliable on borderless
    // nonactivating panels — AppKit hands the cursor back to the underlying app
    // the moment our panel is composited. The current-AppKit way to force a
    // cursor over a region is a tracking area with .cursorUpdate that calls
    // NSCursor.set() each time the cursor enters or moves within the area.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = cursorTrackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent)   { NSCursor.crosshair.set() }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else { return }
        let rect = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        startPoint = nil
        currentPoint = nil
        needsDisplay = true

        // Reject taps and tiny smudges.
        if rect.width < 10 || rect.height < 10 {
            onCancel?()
            return
        }
        // Translate view-local coords to global screen coords (bottom-left origin).
        let screenOrigin = window?.frame.origin ?? .zero
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width,
            height: rect.height
        )
        onComplete?(globalRect)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the whole screen.
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        // Carve out the selection (transparent so the desktop shows through).
        if let start = startPoint, let end = currentPoint {
            let sel = NSRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            ctx.clear(sel)

            // Selection border (blue accent matching app theme).
            NSColor(red: 0.45, green: 0.65, blue: 1.0, alpha: 1.0).setStroke()
            let path = NSBezierPath(rect: sel.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.stroke()

            // Size label — "W × H" pill above the selection (or below if near top edge).
            let sizeText = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let textSize = (sizeText as NSString).size(withAttributes: attrs)
            let labelW = textSize.width + 12
            let labelH: CGFloat = 20
            // Above the selection; if no room, place it inside the top of the selection.
            var labelY = sel.maxY + 6
            if labelY + labelH > bounds.maxY { labelY = sel.maxY - labelH - 6 }
            let labelRect = NSRect(x: sel.minX, y: labelY, width: labelW, height: labelH)
            NSColor.black.withAlphaComponent(0.78).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            (sizeText as NSString).draw(
                at: NSPoint(x: labelRect.minX + 6,
                            y: labelRect.minY + (labelRect.height - textSize.height) / 2),
                withAttributes: attrs
            )
        }
    }
}
