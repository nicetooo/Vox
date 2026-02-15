import CoreGraphics
import Foundation

/// Monitors global key events via CGEventTap to detect:
/// - Right Command hold (push-to-talk for voice input)
/// - Right Option tap (translate selection)
class KeyMonitor {
    // Callbacks
    var onRightCmdDown: (() -> Void)?
    var onRightCmdUp: (() -> Void)?
    var onRightOptTap: (() -> Void)?

    // State tracking
    private var isRightCmdDown = false
    private var isRightOptDown = false
    private var rightOptDownTime: Date?
    private var otherKeyDuringRightOpt = false

    // Device-dependent modifier flags (from IOLLEvent.h)
    private let NX_DEVICERCMDKEYMASK: UInt64  = 0x10
    private let NX_DEVICERALTKEYMASK: UInt64  = 0x40

    // Key codes
    private let kRightCommand: Int64 = 54  // 0x36
    private let kRightOption: Int64  = 61  // 0x3D

    // Max duration for a "tap" (seconds)
    private let tapThreshold: TimeInterval = 0.4

    fileprivate var eventTap: CFMachPort?

    func start() {
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

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue

            log("KeyMonitor: flagsChanged keyCode=\(keyCode) flags=0x\(String(flags, radix: 16))")

            // Right Command key
            if keyCode == kRightCommand {
                let pressed = (flags & NX_DEVICERCMDKEYMASK) != 0
                log("KeyMonitor: Right ⌘ pressed=\(pressed)")
                if pressed && !isRightCmdDown {
                    isRightCmdDown = true
                    onRightCmdDown?()
                } else if !pressed && isRightCmdDown {
                    isRightCmdDown = false
                    onRightCmdUp?()
                }
            }

            // Right Option key
            if keyCode == kRightOption {
                let pressed = (flags & NX_DEVICERALTKEYMASK) != 0
                log("KeyMonitor: Right ⌥ pressed=\(pressed)")
                if pressed && !isRightOptDown {
                    isRightOptDown = true
                    rightOptDownTime = Date()
                    otherKeyDuringRightOpt = false
                } else if !pressed && isRightOptDown {
                    isRightOptDown = false
                    let duration = Date().timeIntervalSince(rightOptDownTime ?? .distantPast)
                    if duration < tapThreshold && !otherKeyDuringRightOpt {
                        onRightOptTap?()
                    }
                }
            }
        } else if type == .keyDown {
            // Track if any other key was pressed while Right Option is held
            if isRightOptDown {
                otherKeyDuringRightOpt = true
            }
        }
    }
}

// C-compatible callback — cannot capture context, uses refcon
private func keyMonitorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap being disabled by the system (e.g. timeout)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let refcon = refcon {
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
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
