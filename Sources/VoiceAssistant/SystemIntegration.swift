import AppKit
import CoreGraphics
import Foundation

/// Handles clipboard operations and simulating keyboard input.
class SystemIntegration {
    /// Get selected text from the frontmost application by simulating Cmd+C.
    /// Returns the selected text or nil.
    func getSelectedText() -> String? {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedContents = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        // Simulate Cmd+C
        simulateKeyPress(keyCode: 0x08, flags: .maskCommand) // 'C' key

        // Wait for clipboard to update
        usleep(150_000) // 150ms

        // Check if clipboard changed
        guard pasteboard.changeCount != savedChangeCount,
              let text = pasteboard.string(forType: .string),
              !text.isEmpty
        else {
            // Restore clipboard
            if let saved = savedContents {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
            return nil
        }

        // Restore original clipboard (we got the text, don't pollute clipboard)
        if let saved = savedContents {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }

        return text
    }

    /// Paste text at the current cursor position by putting it on the clipboard
    /// and simulating Cmd+V.
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let savedContents = pasteboard.string(forType: .string)

        // Put our text on clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Small delay to ensure clipboard is ready
        usleep(50_000) // 50ms

        // Simulate Cmd+V
        simulateKeyPress(keyCode: 0x09, flags: .maskCommand) // 'V' key

        // Restore original clipboard after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let saved = savedContents {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    /// Simulate a key press with modifier flags.
    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        usleep(30_000) // 30ms between down and up
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
