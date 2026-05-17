import CoreGraphics
import Foundation

/// Monitors global key events via CGEventTap to dispatch user-configured hotkey
/// actions. Only modifier-key gestures (tap / hold / double-tap) are supported.
/// Bindings come from Settings and can be reloaded live via `reloadBindings()`.
class KeyMonitor {
    // MARK: - Action callbacks
    var onVoiceInputDown: (() -> Void)?       // hold start (after holdThreshold)
    var onVoiceInputUp: (() -> Void)?         // hold release
    var onVoiceTranslateDown: (() -> Void)?   // hold start — voice → English
    var onVoiceTranslateUp: (() -> Void)?     // hold release — voice → English
    var onToggleHistory: (() -> Void)?        // tap
    var onTranslate: (() -> Void)?            // tap
    var onScreenshot: (() -> Void)?           // double-tap

    // MARK: - Thresholds
    private let tapThreshold: TimeInterval = 0.3
    private let holdThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.3

    // MARK: - Device-dependent modifier flags (IOLLEvent.h)
    private let NX_DEVICELCTLKEYMASK:  UInt64 = 0x00000001
    private let NX_DEVICELCMDKEYMASK:  UInt64 = 0x00000008
    private let NX_DEVICERCMDKEYMASK:  UInt64 = 0x00000010
    private let NX_DEVICELALTKEYMASK:  UInt64 = 0x00000020
    private let NX_DEVICERALTKEYMASK:  UInt64 = 0x00000040
    private let NX_DEVICERCTLKEYMASK:  UInt64 = 0x00002000

    // MARK: - Physical key identity

    /// (side, modifier) identifies a physical modifier key.
    private struct PhysicalKey: Hashable {
        let side: HotkeySide
        let modifier: HotkeyModifier
    }

    /// Per-physical-key runtime state.
    private class KeyState {
        var isDown = false
        var downTime: Date?
        var holdFired = false
        var otherKeyPressed = false
        var lastTapTime: Date?
        var holdTimer: DispatchSourceTimer?
        var tapTimer: DispatchSourceTimer?
    }

    /// Per physical key, the actions bound to it together with the user-configured
    /// gesture that should fire each action. Multiple actions can share a key as
    /// long as their gestures differ (e.g. tap → translate, double-tap → screenshot
    /// both bound to Right ⌥).
    private struct BoundAction {
        let action: HotkeyAction
        let gesture: HotkeyGesture
    }
    private var bindings: [PhysicalKey: [BoundAction]] = [:]
    private var states: [PhysicalKey: KeyState] = [:]

    // MARK: - Permission detection
    private(set) var hasReceivedEvent = false
    let startTime = Date()

    fileprivate var eventTap: CFMachPort?

    // MARK: - Lifecycle

    func start() {
        reloadBindings()

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: keyMonitorCallback,
            userInfo: refcon
        ) else {
            log("KeyMonitor ERROR: Failed to create event tap!")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("KeyMonitor: event tap active")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    /// Rebuild the action → physical-key map from Settings. Cancels any in-flight
    /// timers so a rebind mid-press does not leak state.
    func reloadBindings() {
        for state in states.values {
            state.holdTimer?.cancel()
            state.tapTimer?.cancel()
        }
        states.removeAll()
        bindings.removeAll()

        for action in HotkeyAction.allCases {
            let b = Settings.shared.hotkeyBinding(for: action)
            let key = PhysicalKey(side: b.side, modifier: b.modifier)
            bindings[key, default: []].append(BoundAction(action: action, gesture: b.gesture))
            if states[key] == nil { states[key] = KeyState() }
        }
        log("KeyMonitor: bindings reloaded — \(bindings.count) physical keys, \(HotkeyAction.allCases.count) actions")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        if !hasReceivedEvent {
            hasReceivedEvent = true
            log("KeyMonitor: first event received — Input Monitoring OK")
        }

        if type == .flagsChanged {
            // Sync state of ALL tracked physical keys from the flags field, not
            // just the one matching keyCode. The `flags` bitmask reflects the
            // current real state of every modifier — so even if a previous
            // press/release event was dropped (e.g. by .tapDisabledByUserInput),
            // the next flagsChanged here will self-heal the state machine.
            let flags = event.flags.rawValue
            for (physKey, state) in states {
                let actualPressed = (flags & mask(for: physKey)) != 0
                if actualPressed != state.isDown {
                    log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) \(actualPressed ? "pressed" : "released")")
                    handleModifier(physKey, pressed: actualPressed)
                }
            }
        } else if type == .keyDown {
            // Also sync from flags here — if a modifier release was dropped,
            // typing any regular key will self-heal the state machine.
            let flags = event.flags.rawValue
            for (physKey, state) in states {
                let actualPressed = (flags & mask(for: physKey)) != 0
                if actualPressed != state.isDown {
                    log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) \(actualPressed ? "pressed" : "released") (via keyDown sync)")
                    handleModifier(physKey, pressed: actualPressed)
                }
            }
            // Any regular key pressed while a modifier is held cancels tap/double-tap.
            for state in states.values where state.isDown {
                state.otherKeyPressed = true
            }
        }
    }

    private func mask(for key: PhysicalKey) -> UInt64 {
        switch (key.side, key.modifier) {
        case (.left,  .cmd):     return NX_DEVICELCMDKEYMASK
        case (.right, .cmd):     return NX_DEVICERCMDKEYMASK
        case (.left,  .option):  return NX_DEVICELALTKEYMASK
        case (.right, .option):  return NX_DEVICERALTKEYMASK
        case (.left,  .control): return NX_DEVICELCTLKEYMASK
        case (.right, .control): return NX_DEVICERCTLKEYMASK
        }
    }

    private func handleModifier(_ physKey: PhysicalKey, pressed: Bool) {
        guard let entries = bindings[physKey], let state = states[physKey] else { return }

        if pressed && !state.isDown {
            state.isDown = true
            state.downTime = Date()
            state.holdFired = false
            state.otherKeyPressed = false

            // If this key has a .hold-gesture action, arm the hold timer.
            if let holdEntry = entries.first(where: { $0.gesture == .hold }) {
                state.holdTimer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + holdThreshold)
                timer.setEventHandler { [weak self, weak state] in
                    guard let state = state, state.isDown else { return }
                    state.holdFired = true
                    log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) hold → \(holdEntry.action.displayName)")
                    self?.fireHoldDown(holdEntry.action)
                }
                timer.resume()
                state.holdTimer = timer
            }

        } else if !pressed && state.isDown {
            state.isDown = false
            state.holdTimer?.cancel()
            state.holdTimer = nil

            if state.holdFired {
                // Was holding — release the hold action.
                state.holdFired = false
                if let holdEntry = entries.first(where: { $0.gesture == .hold }) {
                    fireHoldUp(holdEntry.action)
                }
                return
            }

            // Short press — candidate for tap / double-tap.
            let duration = Date().timeIntervalSince(state.downTime ?? .distantPast)
            guard duration < tapThreshold, !state.otherKeyPressed else { return }

            let tapEntry = entries.first { $0.gesture == .tap }
            let doubleTapEntry = entries.first { $0.gesture == .doubleTap }

            if let doubleEntry = doubleTapEntry {
                // Need to distinguish tap from first-half of double-tap.
                if let last = state.lastTapTime,
                   Date().timeIntervalSince(last) < doubleTapWindow {
                    // Second tap — fire double-tap immediately.
                    state.tapTimer?.cancel()
                    state.tapTimer = nil
                    state.lastTapTime = nil
                    log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) double-tap → \(doubleEntry.action.displayName)")
                    fireTap(doubleEntry.action)
                } else {
                    // First tap — wait to see if a second follows.
                    state.lastTapTime = Date()
                    state.tapTimer?.cancel()
                    let timer = DispatchSource.makeTimerSource(queue: .main)
                    timer.schedule(deadline: .now() + doubleTapWindow)
                    timer.setEventHandler { [weak self, weak state] in
                        state?.lastTapTime = nil
                        state?.tapTimer = nil
                        if let tap = tapEntry {
                            log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) tap → \(tap.action.displayName)")
                            self?.fireTap(tap.action)
                        }
                    }
                    timer.resume()
                    state.tapTimer = timer
                }
            } else if let tap = tapEntry {
                // No double-tap bound on this key — tap fires immediately.
                log("KeyMonitor: \(physKey.side.displayName) \(physKey.modifier.symbol) tap → \(tap.action.displayName)")
                fireTap(tap.action)
            }
        }
    }

    // MARK: - Action dispatch

    private func fireTap(_ action: HotkeyAction) {
        switch action {
        case .toggleHistory:  onToggleHistory?()
        case .translate:      onTranslate?()
        case .screenshot:     onScreenshot?()
        case .voiceInput,
             .voiceTranslate: break  // hold-only actions
        }
    }

    private func fireHoldDown(_ action: HotkeyAction) {
        switch action {
        case .voiceInput:     onVoiceInputDown?()
        case .voiceTranslate: onVoiceTranslateDown?()
        default: break
        }
    }

    private func fireHoldUp(_ action: HotkeyAction) {
        switch action {
        case .voiceInput:     onVoiceInputUp?()
        case .voiceTranslate: onVoiceTranslateUp?()
        default: break
        }
    }
}

// C-compatible callback — cannot capture context, uses refcon.
private func keyMonitorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap being disabled by the system (timeout or permission change).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        log("KeyMonitor: event tap disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")), re-enabling...")
        if let refcon = refcon {
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("KeyMonitor: event tap re-enabled")
            }
        }
        return Unmanaged.passUnretained(event)
    }

    if let refcon = refcon {
        let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
