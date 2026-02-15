import Foundation

/// Calls the locally installed mlx_whisper CLI to transcribe audio.
class WhisperService {
    private var whisperPath: String { Settings.mlxWhisperPath }
    private let outputDir = "/tmp"
    private let outputName = "va_result"

    /// Transcribe audio file. Returns the text or nil on failure.
    /// This is a blocking call — run on a background thread.
    func transcribe(audioPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("Whisper: Audio file not found: \(audioPath)")
            return nil
        }

        // Clean previous result
        let resultPath = "\(outputDir)/\(outputName).txt"
        try? FileManager.default.removeItem(atPath: resultPath)

        // Build arguments using current settings
        let model = Settings.shared.whisperModel
        var args = [
            audioPath,
            "--model", model,
            "--output-format", "txt",
            "--output-dir", outputDir,
            "--output-name", outputName,
        ]

        // Add language if exactly one is selected
        if let lang = Settings.shared.whisperLanguageArg {
            args += ["--language", lang]
            log("Whisper: using language = \(lang)")
        } else {
            log("Whisper: auto-detecting language")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = args

        // Capture stderr for diagnostics
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        log("Whisper: starting transcription (model: \(model))...")
        log("Whisper: args = \(args)")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Whisper: failed to run: \(error)")
            return nil
        }

        // Read stderr
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let stderrStr = String(data: stderrData, encoding: .utf8), !stderrStr.isEmpty {
            log("Whisper stderr: \(stderrStr.prefix(2000))")
        }

        guard process.terminationStatus == 0 else {
            log("Whisper: exited with status \(process.terminationStatus)")
            return nil
        }

        // Read result
        guard let text = try? String(contentsOfFile: resultPath, encoding: .utf8) else {
            log("Whisper: could not read result file")
            return nil
        }

        var result = cleanupTranscription(text)
        result = convertChineseIfNeeded(result)
        log("Whisper: result = \"\(result)\"")
        return result
    }

    // MARK: - Line Cleanup

    /// Merge Whisper's multi-line segment output into a single line with spaces.
    private func cleanupTranscription(_ text: String) -> String {
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Chinese Conversion

    /// Convert between simplified and traditional Chinese based on user settings.
    /// Uses macOS built-in ICU transforms — no external dependencies.
    private func convertChineseIfNeeded(_ text: String) -> String {
        if Settings.shared.chineseSimplified {
            // Convert traditional → simplified
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
            let converted = mutable as String
            if converted != text {
                log("Whisper: converted traditional → simplified")
            }
            return converted
        } else if Settings.shared.chineseTraditional {
            // Convert simplified → traditional
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
            let converted = mutable as String
            if converted != text {
                log("Whisper: converted simplified → traditional")
            }
            return converted
        }
        // Both or neither selected — keep as-is
        return text
    }
}
