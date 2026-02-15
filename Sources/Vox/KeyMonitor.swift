import CoreGraphics
import Foundation

/// Monitors global key events via CGEventTap to detect:
/// - Right Command tap (toggle History)
/// - Right Command hold (push-to-talk for voice input)
/// - Right Option tap (translate selection)
class KeyMonitor {
    // Callbacks
    var onRightCmdTap: (() -> Void)?
    var onRightCmdDown: (() -> Void)?
    var onRightCmdUp: (() -> Void)?
    var onRightOptTap: (() -> Void)?
    var onRightOptDoubleTap: (() -> Void)?

    // State tracking
    private var isRightCmdDown = false
    private var isRightCmdRecording = false    // true once hold threshold passed
    private var rightCmdDownTime: Date?
    private var isRightOptDown = false
    private var rightOptDownTime: Date?
    private var otherKeyDuringRightOpt = false
    private var holdTimer: DispatchSourceTimer?
    private var rightOptLastTapTime: Date?
    private var rightOptTapTimer: DispatchSourceTimer?

    // Device-dependent modifier flags (from IOLLEvent.h)
    private let NX_DEVICERCMDKEYMASK: UInt64  = 0x10
    private let NX_DEVICERALTKEYMASK: UInt64  = 0x40

    // Key codes
    private let kRightCommand: Int64 = 54  // 0x36
    private let kRightOption: Int64  = 61  // 0x3D

    // Thresholds
    private let tapThreshold: TimeInterval = 0.3    // tap if released within this
    private let holdThreshold: TimeInterval = 0.3   // start recording after this
    private let doubleTapWindow: TimeInterval = 0.3 // double-tap if two taps within this

    // Permission detection: set to true once any event arrives
    private(set) var hasReceivedEvent = false
    let startTime = Date()

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
        if !hasReceivedEvent {
            hasReceivedEvent = true
            log("KeyMonitor: first event received — Input Monitoring OK")
        }

        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue

            log("KeyMonitor: flagsChanged keyCode=\(keyCode) flags=0x\(String(flags, radix: 16))")

            // Right Command key: tap = toggle History, hold = record
            if keyCode == kRightCommand {
                let pressed = (flags & NX_DEVICERCMDKEYMASK) != 0
                log("KeyMonitor: Right ⌘ pressed=\(pressed)")
                if pressed && !isRightCmdDown {
                    isRightCmdDown = true
                    isRightCmdRecording = false
                    rightCmdDownTime = Date()

                    // Start a hold timer — if key is still held after threshold, start recording
                    holdTimer?.cancel()
                    let timer = DispatchSource.makeTimerSource(queue: .main)
                    timer.schedule(deadline: .now() + holdThreshold)
                    timer.setEventHandler { [weak self] in
                        guard let self = self, self.isRightCmdDown else { return }
                        self.isRightCmdRecording = true
                        log("KeyMonitor: Right ⌘ hold → start recording")
                        self.onRightCmdDown?()
                    }
                    timer.resume()
                    holdTimer = timer

                } else if !pressed && isRightCmdDown {
                    isRightCmdDown = false
                    holdTimer?.cancel()
                    holdTimer = nil

                    if isRightCmdRecording {
                        // Was recording → stop
                        isRightCmdRecording = false
                        onRightCmdUp?()
                    } else {
                        // Short press → tap → toggle History
                        log("KeyMonitor: Right ⌘ tap → toggle History")
                        onRightCmdTap?()
                    }
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
                        // This is a tap — check for double tap
                        let now = Date()
                        if let lastTap = rightOptLastTapTime,
                           now.timeIntervalSince(lastTap) < doubleTapWindow {
                            // Double tap detected
                            rightOptTapTimer?.cancel()
                            rightOptTapTimer = nil
                            rightOptLastTapTime = nil
                            log("KeyMonitor: Right ⌥ double-tap → screenshot")
                            onRightOptDoubleTap?()
                        } else {
                            // First tap — wait to see if double tap follows
                            rightOptLastTapTime = now
                            rightOptTapTimer?.cancel()
                            let timer = DispatchSource.makeTimerSource(queue: .main)
                            timer.schedule(deadline: .now() + doubleTapWindow)
                            timer.setEventHandler { [weak self] in
                                self?.rightOptLastTapTime = nil
                                self?.rightOptTapTimer = nil
                                log("KeyMonitor: Right ⌥ single tap → translate")
                                self?.onRightOptTap?()
                            }
                            timer.resume()
                            rightOptTapTimer = timer
                        }
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
    // Handle tap being disabled by the system (e.g. timeout or permission change)
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
