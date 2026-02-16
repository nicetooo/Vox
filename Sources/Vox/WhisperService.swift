import CoreML
import Foundation
import NaturalLanguage
import WhisperKit

/// Transcribes audio using WhisperKit (CoreML-native, no Python/ffmpeg needed).
class WhisperService {
    private var whisperKit: WhisperKit?
    private var loadedModel: String = ""
    private(set) var isLoading = false

    /// Whether a model is loaded and ready for transcription
    var isModelReady: Bool { whisperKit != nil && !loadedModel.isEmpty }

    /// Transcribe audio file. Returns the text or nil on failure.
    /// Call from a Task {} context (async).
    func transcribe(audioPath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("Whisper: audio file not found: \(audioPath)")
            return nil
        }

        // Ensure model is loaded
        let model = Settings.shared.whisperModel
        log("Whisper: transcribe called, model=\(model), loaded=\(loadedModel), kit=\(whisperKit == nil ? "nil" : "ok"), isLoading=\(isLoading)")
        if whisperKit == nil || loadedModel != model {
            guard await loadModel(model) else { return nil }
        }

        guard let kit = whisperKit else {
            log("Whisper: not initialized")
            return nil
        }

        // Build decoding options
        let forcedLang = Settings.shared.whisperLanguageArg
        var options = DecodingOptions()
        options.language = forcedLang
        options.detectLanguage = (forcedLang == nil)
        options.verbose = false

        log("Whisper: transcribing (model: \(model), lang: \(forcedLang ?? "auto"))...")
        let startTime = Date()

        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)

            guard let result = results.first else {
                log("Whisper: no result")
                return nil
            }

            var rawText = result.text
            let detectedLang = result.language
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            log("Whisper: done in \(elapsed)s, detected=\(detectedLang), text=\(rawText.prefix(100))")

            // If auto-detecting, verify result language matches user's selection
            if forcedLang == nil && !Settings.shared.selectedLanguages.isEmpty {
                let cleaned = cleanupTranscription(rawText)
                if !isLanguageExpected(cleaned) {
                    if let retryLang = bestRetryLanguage() {
                        log("Whisper: language mismatch, retrying with forced '\(retryLang)'")
                        var retryOptions = options
                        retryOptions.language = retryLang
                        retryOptions.detectLanguage = false
                        if let retryResults: [TranscriptionResult] = try? await kit.transcribe(audioPath: audioPath, decodeOptions: retryOptions),
                           let retryResult = retryResults.first {
                            rawText = retryResult.text
                        }
                    }
                }
            }

            var finalText = cleanupTranscription(rawText)
            finalText = convertChineseIfNeeded(finalText)
            log("Whisper: result = \"\(finalText)\"")
            return finalText

        } catch {
            log("Whisper: transcription failed: \(error)")
            return nil
        }
    }

    // MARK: - Model Loading

    /// Load a WhisperKit model. Returns true on success.
    func loadModel(_ variant: String) async -> Bool {
        guard !isLoading else {
            log("Whisper: already loading a model, please wait")
            return false
        }
        isLoading = true
        defer { isLoading = false }

        log("Whisper: loading model '\(variant)'...")
        let startTime = Date()

        do {
            // Skip ANE (Neural Engine) — CoreML's ANE compilation hangs on large models.
            // Use CPU+GPU only, which loads instantly and is still fast on Apple Silicon.
            let compute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU,
                prefillCompute: .cpuAndGPU
            )

            let config = WhisperKitConfig(
                model: variant,
                downloadBase: Settings.modelStorageDir,
                computeOptions: compute,
                verbose: true,
                logLevel: .debug,
                prewarm: false,
                load: true,
                download: true
            )

            log("Whisper: calling WhisperKit init (variant=\(variant), base=\(Settings.modelStorageDir.path))...")
            whisperKit = try await WhisperKit(config)
            loadedModel = variant

            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            log("Whisper: model '\(variant)' loaded in \(elapsed)s ✓")
            return true
        } catch {
            log("Whisper: FAILED to load model '\(variant)': \(error)")
            whisperKit = nil
            loadedModel = ""
            return false
        }
    }

    /// Unload the current model to free memory
    func unloadModel() {
        whisperKit = nil
        loadedModel = ""
        log("Whisper: model unloaded")
    }

    // MARK: - Language Verification

    /// Map internal language codes to Whisper language codes
    private static let whisperLangMap: [String: String] = [
        "zh-Hans": "zh",
        "zh-Hant": "zh",
    ]

    private func isLanguageExpected(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let detected = recognizer.dominantLanguage else { return true }

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

    private func bestRetryLanguage() -> String? {
        let langs = Settings.shared.selectedLanguages
        guard let first = langs.first else { return nil }
        return WhisperService.whisperLangMap[first] ?? first
    }

    // MARK: - Line Cleanup

    private func cleanupTranscription(_ text: String) -> String {
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Chinese Conversion

    private func convertChineseIfNeeded(_ text: String) -> String {
        if Settings.shared.chineseSimplified {
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
            let converted = mutable as String
            if converted != text { log("Whisper: converted traditional → simplified") }
            return converted
        } else if Settings.shared.chineseTraditional {
            let mutable = NSMutableString(string: text)
            CFStringTransform(mutable, nil, "Hans-Hant" as CFString, false)
            let converted = mutable as String
            if converted != text { log("Whisper: converted simplified → traditional") }
            return converted
        }
        return text
    }
}
