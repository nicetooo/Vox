import AppKit
import Foundation

// Log to file since stdout is swallowed in GUI apps
func log(_ msg: String) {
    let line = "[\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))] \(msg)\n"
    let logPath = "/tmp/va.log"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
    NSLog("%@", msg)
}

log("main.swift starting")

let app = NSApplication.shared
log("NSApplication created")

app.setActivationPolicy(.accessory)
log("Activation policy set to .accessory")

let delegate = AppDelegate()
app.delegate = delegate
log("Delegate set, calling app.run()")

app.run()
