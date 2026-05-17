import Foundation
import WhisperKit

// MARK: - Model Info

struct WhisperModelInfo {
    let name: String         // WhisperKit model variant name
    let displayName: String  // User-friendly name
    let size: String         // Approximate download size
    let note: String         // One-line pros/cons summary shown under the name
}

// MARK: - Settings (UserDefaults backed)

class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // MARK: - Popular Whisper Models (WhisperKit CoreML format)
    //
    // Curated list — older / smaller variants (large-v2, distil-large-v3, medium,
    // base, tiny) have been removed because they're either superseded by Turbo or
    // too low-quality to be useful (especially for non-English).

    /// Model display names stay English (technical identifiers users expect),
    /// but the `note` field is localized.
    static var popularModels: [WhisperModelInfo] {
        [
            WhisperModelInfo(
                name: "large-v3",
                displayName: "Large V3",
                size: "~3 GB",
                note: L("model.large_v3.note")
            ),
            WhisperModelInfo(
                name: "large-v3-v20240930",
                displayName: "Large V3 Turbo",
                size: "~1.6 GB",
                note: L("model.large_v3_turbo.note")
            ),
            WhisperModelInfo(
                name: "small",
                displayName: "Small",
                size: "~500 MB",
                note: L("model.small.note")
            ),
        ]
    }

    // MARK: - Available Languages

    // Ordered by popularity for typical Znote users: English first (global
    // lingua franca + most Whisper users), then Chinese family (Simplified +
    // Traditional kept adjacent), then other CJK, then European, then others.
    static let availableLanguages: [LanguageOption] = [
        LanguageOption(code: "en", name: "English"),
        LanguageOption(code: "zh-Hans", name: "简体中文 (Simplified)"),
        LanguageOption(code: "zh-Hant", name: "繁體中文 (Traditional)"),
        LanguageOption(code: "ja", name: "日本語 (Japanese)"),
        LanguageOption(code: "ko", name: "한국어 (Korean)"),
        LanguageOption(code: "es", name: "Español (Spanish)"),
        LanguageOption(code: "fr", name: "Français (French)"),
        LanguageOption(code: "de", name: "Deutsch (German)"),
        LanguageOption(code: "it", name: "Italiano (Italian)"),
        LanguageOption(code: "pt", name: "Português (Portuguese)"),
        LanguageOption(code: "ru", name: "Русский (Russian)"),
        LanguageOption(code: "ar", name: "العربية (Arabic)"),
        LanguageOption(code: "hi", name: "हिन्दी (Hindi)"),
        LanguageOption(code: "yue", name: "粵語 (Cantonese)"),
        LanguageOption(code: "th", name: "ภาษาไทย (Thai)"),
        LanguageOption(code: "vi", name: "Tiếng Việt (Vietnamese)"),
        LanguageOption(code: "id", name: "Bahasa Indonesia"),
    ]

    // MARK: - Language Settings

    var selectedLanguages: [String] {
        get { defaults.stringArray(forKey: "selectedLanguages") ?? [] }
        set { defaults.set(newValue, forKey: "selectedLanguages") }
    }

    /// Map internal language codes to Whisper language codes
    private static let whisperLangMap: [String: String] = [
        "zh-Hans": "zh",
        "zh-Hant": "zh",
    ]

    /// Single language arg for Whisper, or nil for auto-detect.
    var whisperLanguageArg: String? {
        let langs = selectedLanguages
        let whisperLangs = Set(langs.map { Settings.whisperLangMap[$0] ?? $0 })
        return whisperLangs.count == 1 ? whisperLangs.first : nil
    }

    /// Whether to convert Chinese output to simplified
    var chineseSimplified: Bool {
        let langs = selectedLanguages
        return langs.contains("zh-Hans") && !langs.contains("zh-Hant")
    }

    /// Whether to convert Chinese output to traditional
    var chineseTraditional: Bool {
        let langs = selectedLanguages
        return langs.contains("zh-Hant") && !langs.contains("zh-Hans")
    }

    // MARK: - Model Settings

    var whisperModel: String {
        get {
            let stored = defaults.string(forKey: "whisperModel") ?? ""
            // Migrate from old mlx-community format or empty
            if stored.contains("mlx-community") || stored.isEmpty {
                return "large-v3"
            }
            // Migrate from removed model variants (large-v2 / distil-large-v3 /
            // medium / base / tiny / etc.) → fall back to large-v3 so the user
            // doesn't get stuck on an option that no longer appears in Settings.
            let supported = Set(Settings.popularModels.map { $0.name })
            if !supported.contains(stored) {
                log("Settings: stored model '\(stored)' no longer offered — migrating to large-v3")
                return "large-v3"
            }
            return stored
        }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    // MARK: - Audio Detection

    var silenceThreshold: Float {
        get {
            let v = defaults.float(forKey: "silenceThreshold")
            return v > 0 ? v : 0.05
        }
        set { defaults.set(newValue, forKey: "silenceThreshold") }
    }

    var minRecordingDuration: TimeInterval {
        get {
            let v = defaults.double(forKey: "minRecordingDuration")
            return v > 0 ? v : 0.5
        }
        set { defaults.set(newValue, forKey: "minRecordingDuration") }
    }

    // MARK: - WhisperKit Model Management

    /// Model storage directory — ~/Library/Application Support/Znote/Models/
    /// NOT ~/Documents (macOS privacy restricted)
    static let modelStorageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Znote/Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("Model storage: \(dir.path)")
        return dir
    }()

    /// Scan modelStorageDir for downloaded model variant folders.
    /// WhisperKit downloads into: modelStorageDir/models/argmaxinc/whisperkit-coreml/<variant>/
    static func cachedModelNames() -> Set<String> {
        let fm = FileManager.default
        let repoDir = modelStorageDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")

        var models = Set<String>()
        guard let entries = try? fm.contentsOfDirectory(atPath: repoDir.path) else { return models }

        for entry in entries {
            let dirPath = repoDir.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Check it contains CoreML model files
            if let contents = try? fm.contentsOfDirectory(atPath: dirPath.path),
               contents.contains(where: { $0.hasSuffix(".mlmodelc") || $0 == "config.json" }) {
                // Extract variant: "openai_whisper-large-v3" → "large-v3"
                let variant = entry
                    .replacingOccurrences(of: "openai_whisper-", with: "")
                    .replacingOccurrences(of: "distil-whisper_distil-", with: "distil-")
                models.insert(variant)
            }
        }
        return models
    }

    /// Get the local folder path for a downloaded model variant (or nil)
    static func modelFolder(for variant: String) -> String? {
        let fm = FileManager.default
        let repoDir = modelStorageDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")

        guard let entries = try? fm.contentsOfDirectory(atPath: repoDir.path) else { return nil }
        for entry in entries {
            let extracted = entry
                .replacingOccurrences(of: "openai_whisper-", with: "")
                .replacingOccurrences(of: "distil-whisper_distil-", with: "distil-")
            if extracted == variant {
                return repoDir.appendingPathComponent(entry).path
            }
        }
        return nil
    }

    /// Download a WhisperKit model with progress reporting
    static func downloadModel(_ variant: String, onProgress: @escaping (DownloadProgress) -> Void, onComplete: @escaping (Bool) -> Void) {
        Task {
            do {
                log("Downloading model '\(variant)' to \(modelStorageDir.path)")
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 0.0, fileName: variant, message: L("download.starting", variant)))
                }

                let modelURL = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelStorageDir,
                    progressCallback: { progress in
                        let pct = progress.fractionCompleted
                        let msg = L("download.progress", pct * 100)
                        DispatchQueue.main.async {
                            onProgress(DownloadProgress(percent: pct, fileName: variant, message: msg))
                        }
                    }
                )

                log("Model download success: \(variant) → \(modelURL.path)")
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 1.0, fileName: variant, message: L("download.complete")))
                    onComplete(true)
                }
            } catch {
                log("Model download failed: \(variant) — \(error)")
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 0, fileName: variant, message: L("download.error", error.localizedDescription)))
                    onComplete(false)
                }
            }
        }
    }

    /// Delete a downloaded model
    static func deleteModel(_ modelName: String) -> Bool {
        let fm = FileManager.default
        let repoDir = modelStorageDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")

        guard let entries = try? fm.contentsOfDirectory(atPath: repoDir.path) else {
            log("Delete model: repo dir not found")
            return false
        }

        for entry in entries {
            let variant = entry
                .replacingOccurrences(of: "openai_whisper-", with: "")
                .replacingOccurrences(of: "distil-whisper_distil-", with: "distil-")
            if variant == modelName {
                let fullPath = repoDir.appendingPathComponent(entry)
                do {
                    try fm.removeItem(at: fullPath)
                    log("Delete model: removed \(modelName) (\(fullPath.path))")
                    return true
                } catch {
                    log("Delete model: failed — \(error)")
                    return false
                }
            }
        }
        log("Delete model: not found — \(modelName)")
        return false
    }

    /// Get disk size of a cached model
    static func cachedModelSize(_ modelName: String) -> String {
        guard let folder = modelFolder(for: modelName) else { return "?" }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: folder) else { return "?" }

        var totalSize: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            if let attrs = try? fm.attributesOfItem(atPath: folder + "/" + file),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        if totalSize > 1_000_000_000 {
            return String(format: "%.1f GB", Double(totalSize) / 1_000_000_000)
        } else if totalSize > 1_000_000 {
            return String(format: "%.0f MB", Double(totalSize) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(totalSize) / 1_000)
    }

    /// Download progress info
    struct DownloadProgress {
        let percent: Double
        let fileName: String
        let message: String
    }
}

struct LanguageOption {
    let code: String
    let name: String
}

// MARK: - Hotkey Configuration

enum HotkeySide: String, CaseIterable {
    case left, right
    var displayName: String { self == .left ? L("hotkey.side.left") : L("hotkey.side.right") }
}

enum HotkeyModifier: String, CaseIterable {
    case cmd, option, control
    var symbol: String {
        switch self {
        case .cmd: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
}

enum HotkeyGesture: String, CaseIterable {
    case tap, hold, doubleTap
    var displayName: String {
        switch self {
        case .tap: return L("hotkey.gesture.tap")
        case .hold: return L("hotkey.gesture.hold")
        case .doubleTap: return L("hotkey.gesture.double_tap")
        }
    }
}

enum HotkeyAction: String, CaseIterable {
    case voiceInput, voiceTranslate, toggleHistory, translate, screenshot

    var displayName: String {
        switch self {
        case .voiceInput: return L("hotkey.action.voice_input")
        case .voiceTranslate: return L("hotkey.action.voice_translate")
        case .toggleHistory: return L("hotkey.action.toggle_history")
        case .translate: return L("hotkey.action.translate")
        case .screenshot: return L("hotkey.action.screenshot")
        }
    }

    /// Default gesture (used when user hasn't customized it).
    var defaultGesture: HotkeyGesture {
        switch self {
        case .voiceInput, .voiceTranslate: return .hold
        case .toggleHistory, .translate: return .tap
        case .screenshot: return .doubleTap
        }
    }

    /// Gestures the user may pick from. voiceInput and voiceTranslate are
    /// locked to .hold (push-to-talk semantics); others swap between tap and
    /// double-tap.
    var allowedGestures: [HotkeyGesture] {
        switch self {
        case .voiceInput, .voiceTranslate: return [.hold]
        case .toggleHistory, .translate, .screenshot: return [.tap, .doubleTap]
        }
    }

    var defaultBinding: HotkeyBinding {
        let base: HotkeyBinding
        switch self {
        case .voiceInput, .toggleHistory:
            base = HotkeyBinding(side: .right, modifier: .cmd, gesture: defaultGesture)
        case .voiceTranslate, .translate, .screenshot:
            // All option-modifier: voiceTranslate gets hold, translate gets tap,
            // screenshot gets double-tap. Three gestures on one physical key —
            // KeyMonitor's binding map supports it.
            base = HotkeyBinding(side: .right, modifier: .option, gesture: defaultGesture)
        }
        return base
    }
}

struct HotkeyBinding: Equatable {
    var side: HotkeySide
    var modifier: HotkeyModifier
    var gesture: HotkeyGesture

    var displayString: String { "\(side.displayName) \(modifier.symbol)" }
}

extension Settings {
    func hotkeyBinding(for action: HotkeyAction) -> HotkeyBinding {
        let sideKey = "hotkey.\(action.rawValue).side"
        let modKey = "hotkey.\(action.rawValue).modifier"
        let gestKey = "hotkey.\(action.rawValue).gesture"
        let side = UserDefaults.standard.string(forKey: sideKey).flatMap(HotkeySide.init(rawValue:))
            ?? action.defaultBinding.side
        let modifier = UserDefaults.standard.string(forKey: modKey).flatMap(HotkeyModifier.init(rawValue:))
            ?? action.defaultBinding.modifier
        let storedGesture = UserDefaults.standard.string(forKey: gestKey).flatMap(HotkeyGesture.init(rawValue:))
        // Clamp to allowedGestures so an old/invalid stored value can't break the action.
        let gesture = (storedGesture.map { action.allowedGestures.contains($0) ? $0 : action.defaultGesture })
            ?? action.defaultGesture
        return HotkeyBinding(side: side, modifier: modifier, gesture: gesture)
    }

    func setHotkeyBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        UserDefaults.standard.set(binding.side.rawValue, forKey: "hotkey.\(action.rawValue).side")
        UserDefaults.standard.set(binding.modifier.rawValue, forKey: "hotkey.\(action.rawValue).modifier")
        UserDefaults.standard.set(binding.gesture.rawValue, forKey: "hotkey.\(action.rawValue).gesture")
    }

    func resetHotkeys() {
        for action in HotkeyAction.allCases {
            setHotkeyBinding(action.defaultBinding, for: action)
        }
    }

    /// Returns pairs of actions that conflict (same side+modifier+gesture).
    func hotkeyConflicts() -> [(HotkeyAction, HotkeyAction)] {
        var conflicts: [(HotkeyAction, HotkeyAction)] = []
        let actions = HotkeyAction.allCases
        for i in 0..<actions.count {
            for j in (i + 1)..<actions.count {
                let a = actions[i], b = actions[j]
                let ba = hotkeyBinding(for: a)
                let bb = hotkeyBinding(for: b)
                if ba == bb {
                    // HotkeyBinding's Equatable now includes gesture, so this implies
                    // same side + modifier + gesture.
                    conflicts.append((a, b))
                }
            }
        }
        return conflicts
    }
}
