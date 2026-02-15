import Foundation
import NaturalLanguage

/// Calls the locally installed mlx_whisper CLI to transcribe audio.
class WhisperService {
    private var whisperPath: String { Settings.mlxWhisperPath }
    private let outputDir = "/tmp"
    private let outputName = "va_result"

    /// Map internal language codes to Whisper language codes
    private static let whisperLangMap: [String: String] = [
        "zh-Hans": "zh",
        "zh-Hant": "zh",
    ]

    /// Transcribe audio file. Returns the text or nil on failure.
    /// This is a blocking call — run on a background thread.
    func transcribe(audioPath: String) -> String? {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("Whisper: Audio file not found: \(audioPath)")
            return nil
        }

        let forcedLang = Settings.shared.whisperLanguageArg
        guard var rawText = runWhisper(audioPath: audioPath, language: forcedLang) else {
            return nil
        }

        // If auto-detecting (multiple languages selected), verify result language.
        // Whisper sometimes misdetects — e.g. Chinese as Korean.
        // If the result language isn't in the user's selected set, retry with forced language.
        if forcedLang == nil && !Settings.shared.selectedLanguages.isEmpty {
            let cleaned = cleanupTranscription(rawText)
            if !isLanguageExpected(cleaned) {
                if let retryLang = bestRetryLanguage() {
                    log("Whisper: language mismatch, retrying with forced '\(retryLang)'")
                    if let retryText = runWhisper(audioPath: audioPath, language: retryLang) {
                        rawText = retryText
                    }
                }
            }
        }

        var result = cleanupTranscription(rawText)
        result = convertChineseIfNeeded(result)
        log("Whisper: result = \"\(result)\"")
        return result
    }

    // MARK: - Whisper CLI

    private func runWhisper(audioPath: String, language: String?) -> String? {
        // Clean previous result
        let resultPath = "\(outputDir)/\(outputName).txt"
        try? FileManager.default.removeItem(atPath: resultPath)

        let model = Settings.shared.whisperModel
        var args = [
            audioPath,
            "--model", model,
            "--output-format", "txt",
            "--output-dir", outputDir,
            "--output-name", outputName,
        ]

        if let lang = language {
            args += ["--language", lang]
            log("Whisper: using language = \(lang)")
        } else {
            log("Whisper: auto-detecting language")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        log("Whisper: starting transcription (model: \(model))...")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("Whisper: failed to run: \(error)")
            return nil
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if let stderrStr = String(data: stderrData, encoding: .utf8), !stderrStr.isEmpty {
            log("Whisper stderr: \(stderrStr.prefix(2000))")
        }

        guard process.terminationStatus == 0 else {
            log("Whisper: exited with status \(process.terminationStatus)")
            return nil
        }

        guard let text = try? String(contentsOfFile: resultPath, encoding: .utf8) else {
            log("Whisper: could not read result file")
            return nil
        }

        return text
    }

    // MARK: - Language Verification

    /// Check if the transcription result matches one of the user's selected languages
    private func isLanguageExpected(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return true }

        // Compare at base language level: "zh-Hans" → "zh", "ko" → "ko"
        let detectedBase = detected.rawValue.components(separatedBy: "-").first ?? detected.rawValue
        let selectedBases = Set(Settings.shared.selectedLanguages.map {
            $0.components(separatedBy: "-").first ?? $0
        })

        let expected = selectedBases.contains(detectedBase)
        if !expected {
            log("Whisper: NLLanguageRecognizer detected '\(detected.rawValue)' — not in selected \(Settings.shared.selectedLanguages)")
        }
        return expected
    }

    /// Pick the best language to force on retry
    private func bestRetryLanguage() -> String? {
        let langs = Settings.shared.selectedLanguages
        guard let first = langs.first else { return nil }
        return WhisperService.whisperLangMap[first] ?? first
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
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
            let converted = mutable as String
            if converted != text {
                log("Whisper: converted traditional → simplified")
            }
            return converted
        } else if Settings.shared.chineseTraditional {
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
            let converted = mutable as String
            if converted != text {
                log("Whisper: converted simplified → traditional")
            }
            return converted
        }
        return text
    }
}
