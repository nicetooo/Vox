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

    /// Fired on the main actor whenever a model finishes loading successfully.
    /// AppDelegate uses this to swap the recording overlay from "Loading model..."
    /// to the waveform if the user is already holding the record hotkey.
    var onModelReady: (() -> Void)?

    /// Transcribe audio file. Returns the text or nil on failure.
    /// Call from a Task {} context (async).
    ///
    /// - Parameters:
    ///   - audioPath: PCM file produced by AudioRecorder.
    ///   - translate: When true, switch Whisper into `task=translate` mode.
    ///     The decoder outputs ENGLISH text regardless of the spoken language —
    ///     this is Whisper's native any-language → English translation. Source
    ///     language verification + Chinese conversion are skipped in this mode
    ///     because the output is always English by definition.
    func transcribe(audioPath: String, translate: Bool = false) async -> String? {
        guard FileManager.default.fileExists(atPath: audioPath) else {
            log("Whisper: audio file not found: \(audioPath)")
            return nil
        }

        // Ensure model is loaded
        let model = Settings.shared.whisperModel
        log("Whisper: transcribe called, model=\(model), loaded=\(loadedModel), kit=\(whisperKit == nil ? "nil" : "ok"), isLoading=\(isLoading), translate=\(translate)")
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
        // In translate mode we let Whisper auto-detect the source language —
        // forcing the source here also works, but auto is more robust when the
        // user holds the translate hotkey and switches between Chinese / French
        // / etc. without changing Settings.
        if translate {
            options.task = .translate
            options.language = nil
            options.detectLanguage = true
        } else {
            options.language = forcedLang
            options.detectLanguage = (forcedLang == nil)
        }
        options.verbose = false
        options.suppressBlank = true
        // Thresholds tuned to suppress hallucinations on silence
        options.noSpeechThreshold = 0.6
        options.logProbThreshold = -1.0
        options.compressionRatioThreshold = 2.4
        // Speed flags — skip timestamp tokens (decode fewer tokens, also solves
        // the <|0.00|> token leak we saw on multi-segment outputs) and disable
        // temperature fallback retries. Our hallucination filter is the safety
        // net for the edge cases fallback would normally catch.
        options.withoutTimestamps = true
        options.wordTimestamps = false
        options.temperatureFallbackCount = 0

        let modeLabel = translate ? "translate→en" : "transcribe"
        log("Whisper: \(modeLabel) (model: \(model), lang: \(forcedLang ?? "auto"))...")
        let startTime = Date()

        do {
            let results: [TranscriptionResult] = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)

            guard let result = results.first else {
                log("Whisper: no result")
                return nil
            }

            let detectedLang = result.language
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))

            // Filter segments: drop those with high noSpeechProb (hallucination on silence)
            let filteredSegments = result.segments.filter { segment in
                let dominated = segment.noSpeechProb > 0.6 && segment.avgLogprob < -0.7
                if dominated {
                    log("Whisper: dropping segment (noSpeech=\(String(format: "%.2f", segment.noSpeechProb)), avgLogP=\(String(format: "%.2f", segment.avgLogprob))): \"\(segment.text.prefix(60))\"")
                }
                return !dominated
            }

            var rawText = filteredSegments.map { $0.text }.joined(separator: " ")
            if rawText.isEmpty && !result.text.isEmpty {
                // Fallback: if all segments were filtered, use original (rare edge case)
                rawText = result.text
            }
            log("Whisper: done in \(elapsed)s, detected=\(detectedLang), segments=\(result.segments.count)→\(filteredSegments.count), text=\(rawText.prefix(100))")

            // Language verification + retry only makes sense in transcribe mode —
            // in translate mode the OUTPUT language is always English by design,
            // so checking against the user's `selectedLanguages` (which describes
            // input languages) would always fail and trigger pointless retries.
            if !translate, forcedLang == nil, !Settings.shared.selectedLanguages.isEmpty {
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
            finalText = removeTrailingHallucinations(finalText)
            if finalText.isEmpty {
                log("Whisper: result empty after hallucination filtering, discarding")
                return nil
            }
            // Skip Hans/Hant conversion in translate mode (output is English).
            if !translate {
                finalText = convertChineseIfNeeded(finalText)
            }
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
            // ANE (Neural Engine) is 3-5× faster than CPU+GPU on Apple Silicon,
            // but CoreML's ANE compilation is known to hang on the large-v* variants.
            // Use ANE for smaller models, CPU+GPU for large.
            let compute = WhisperService.computeOptions(for: variant)

            let config = WhisperKitConfig(
                model: variant,
                downloadBase: Settings.modelStorageDir,
                computeOptions: compute,
                verbose: true,
                logLevel: .debug,
                prewarm: true,   // warm CoreML compute pipelines at load time
                load: true,
                download: true
            )

            log("Whisper: calling WhisperKit init (variant=\(variant), base=\(Settings.modelStorageDir.path))...")
            whisperKit = try await WhisperKit(config)
            loadedModel = variant

            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startTime))
            log("Whisper: model '\(variant)' loaded in \(elapsed)s ✓")
            let readyCallback = onModelReady
            await MainActor.run { readyCallback?() }
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

    /// Whether a given Whisper variant supports the `task=translate` decoding mode.
    /// OpenAI's Sep 2024 Turbo release (`large-v3-v20240930`) dropped translation
    /// training to win ~8× speed. All other "standard" Whisper variants do support
    /// translate — large-v3, small, medium, etc.
    static func supportsTranslate(_ variant: String) -> Bool {
        let lower = variant.lowercased()
        // Turbo flavours — OpenAI's Sep-2024 release and any "*turbo*" naming.
        if lower.contains("v20240930") || lower.contains("turbo") {
            return false
        }
        return true
    }

    /// Pick compute units per variant. large-v* are forced to CPU+GPU because
    /// CoreML's ANE path is known to hang on their weights; everything else
    /// gets ANE (cpuAndNeuralEngine) which is 3-5× faster on Apple Silicon.
    private static func computeOptions(for variant: String) -> ModelComputeOptions {
        let lower = variant.lowercased()
        let isLarge = lower.hasPrefix("large") || lower.contains("distil-large")
        let unit: MLComputeUnits = isLarge ? .cpuAndGPU : .cpuAndNeuralEngine
        log("Whisper: compute for '\(variant)' = \(isLarge ? "CPU+GPU" : "ANE")")
        return ModelComputeOptions(
            melCompute: .cpuAndGPU,  // mel is small; GPU is fine
            audioEncoderCompute: unit,
            textDecoderCompute: unit,
            prefillCompute: unit
        )
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
        // Strip WhisperKit special tokens: <|startoftranscript|>, <|zh|>,
        // <|transcribe|>, <|0.00|>, <|endoftext|>, etc. These appear on
        // multi-segment outputs because segment.text includes raw timestamps.
        let stripped = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return stripped
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Hallucination Filtering

    /// Common Whisper hallucination phrases that appear on silence/trailing audio.
    /// These are artifacts from YouTube training data endings.
    private static let hallucinationPhrases: Set<String> = [
        // "Thank you" family
        "thank", "thank.", "thank!",
        "thanks", "thanks.", "thanks!",
        "thank you", "thank you.", "thank you!",
        "thank you so much", "thank you so much.",
        "thank you for watching", "thank you for watching.",
        "thanks for watching", "thanks for watching.", "thanks for watching!",
        "thanks a lot", "thanks a lot.",
        // Subscribe / CTA
        "like and subscribe", "like and subscribe.",
        "subscribe", "subscribe.", "please subscribe",
        // Sign-offs
        "see you next time", "see you next time.",
        "see you in the next video", "see you in the next video.",
        "bye", "bye.", "bye bye", "bye bye.",
        "goodbye", "goodbye.",
        "the end", "the end.",
        // Single-word fragments
        "you", "you.",
        "music",
        "♪",
        "...",
        // Known auto-subtitle artifacts
        "subtitles by the amara.org community",
        "transcribed by https://otter.ai",
    ]

    /// Remove hallucination phrases from the end of transcription.
    /// Works for both pure-hallucination results and trailing hallucinations.
    private func removeTrailingHallucinations(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true

        // Iteratively strip trailing hallucination phrases
        while changed {
            changed = false
            let lower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // Check if the entire remaining text is a hallucination
            if WhisperService.hallucinationPhrases.contains(lower) {
                log("Whisper: filtered pure hallucination: \"\(result)\"")
                return ""
            }

            // Check if text ends with a hallucination phrase
            for phrase in WhisperService.hallucinationPhrases {
                if lower.hasSuffix(phrase) {
                    // Make sure it's a separate phrase (preceded by space/punctuation or is the whole string)
                    let prefixEnd = result.index(result.endIndex, offsetBy: -phrase.count)
                    if prefixEnd == result.startIndex {
                        // Entire text is the hallucination
                        log("Whisper: filtered pure hallucination: \"\(result)\"")
                        return ""
                    }
                    let charBefore = result[result.index(before: prefixEnd)]
                    if charBefore == " " || charBefore == "," || charBefore == "." ||
                       charBefore == "!" || charBefore == "?" || charBefore == "。" ||
                       charBefore == "，" || charBefore == "、" {
                        let stripped = String(result[result.startIndex..<prefixEnd])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: " ,，.。、"))
                        log("Whisper: stripped trailing hallucination \"\(phrase)\" → \"\(stripped.suffix(30))\"")
                        result = stripped
                        changed = true
                        break
                    }
                }
            }
        }

        return result
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
