import Foundation
import WhisperKit

// MARK: - Model Info

struct WhisperModelInfo {
    let name: String         // WhisperKit model variant name
    let displayName: String  // User-friendly name
    let size: String         // Approximate download size
}

// MARK: - Settings (UserDefaults backed)

class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // MARK: - Popular Whisper Models (WhisperKit CoreML format)

    static let popularModels: [WhisperModelInfo] = [
        WhisperModelInfo(name: "large-v3", displayName: "Large V3 (best quality)", size: "~3 GB"),
        WhisperModelInfo(name: "large-v2", displayName: "Large V2", size: "~3 GB"),
        WhisperModelInfo(name: "distil-large-v3", displayName: "Distil Large V3 (fast+good)", size: "~1.5 GB"),
        WhisperModelInfo(name: "medium", displayName: "Medium", size: "~1.5 GB"),
        WhisperModelInfo(name: "small", displayName: "Small", size: "~500 MB"),
        WhisperModelInfo(name: "base", displayName: "Base", size: "~150 MB"),
        WhisperModelInfo(name: "tiny", displayName: "Tiny (fastest)", size: "~80 MB"),
    ]

    // MARK: - Available Languages

    static let availableLanguages: [LanguageOption] = [
        LanguageOption(code: "zh-Hans", name: "简体中文 (Simplified)"),
        LanguageOption(code: "zh-Hant", name: "繁體中文 (Traditional)"),
        LanguageOption(code: "en", name: "English"),
        LanguageOption(code: "ja", name: "日本語 (Japanese)"),
        LanguageOption(code: "ko", name: "한국어 (Korean)"),
        LanguageOption(code: "yue", name: "粵語 (Cantonese)"),
        LanguageOption(code: "es", name: "Español (Spanish)"),
        LanguageOption(code: "fr", name: "Français (French)"),
        LanguageOption(code: "de", name: "Deutsch (German)"),
        LanguageOption(code: "ru", name: "Русский (Russian)"),
        LanguageOption(code: "pt", name: "Português (Portuguese)"),
        LanguageOption(code: "it", name: "Italiano (Italian)"),
        LanguageOption(code: "ar", name: "العربية (Arabic)"),
        LanguageOption(code: "hi", name: "हिन्दी (Hindi)"),
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
            // Remove large-v3-turbo (not available in WhisperKit)
            if stored == "large-v3-turbo" {
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
                // Extract variant: "openai_whisper-large-v3-turbo" → "large-v3-turbo"
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
                    onProgress(DownloadProgress(percent: 0.0, fileName: variant, message: "Downloading \(variant)..."))
                }

                let modelURL = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: modelStorageDir,
                    progressCallback: { progress in
                        let pct = progress.fractionCompleted
                        let msg = String(format: "Downloading... %.0f%%", pct * 100)
                        DispatchQueue.main.async {
                            onProgress(DownloadProgress(percent: pct, fileName: variant, message: msg))
                        }
                    }
                )

                log("Model download success: \(variant) → \(modelURL.path)")
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 1.0, fileName: variant, message: "Download complete"))
                    onComplete(true)
                }
            } catch {
                log("Model download failed: \(variant) — \(error)")
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 0, fileName: variant, message: "Error: \(error.localizedDescription)"))
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
    var displayName: String { self == .left ? "Left" : "Right" }
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

enum HotkeyGesture: String {
    case tap, hold, doubleTap
    var displayName: String {
        switch self {
        case .tap: return "Tap"
        case .hold: return "Hold"
        case .doubleTap: return "Double-tap"
        }
    }
}

enum HotkeyAction: String, CaseIterable {
    case voiceInput, toggleHistory, translate, screenshot

    var displayName: String {
        switch self {
        case .voiceInput: return "Voice Input"
        case .toggleHistory: return "Toggle History"
        case .translate: return "Translate Selection"
        case .screenshot: return "Screenshot"
        }
    }

    /// Gesture is fixed per action (strong semantic coupling).
    var gesture: HotkeyGesture {
        switch self {
        case .voiceInput: return .hold
        case .toggleHistory, .translate: return .tap
        case .screenshot: return .doubleTap
        }
    }

    var defaultBinding: HotkeyBinding {
        switch self {
        case .voiceInput, .toggleHistory:
            return HotkeyBinding(side: .right, modifier: .cmd)
        case .translate, .screenshot:
            return HotkeyBinding(side: .right, modifier: .option)
        }
    }
}

struct HotkeyBinding: Equatable {
    var side: HotkeySide
    var modifier: HotkeyModifier

    var displayString: String { "\(side.displayName) \(modifier.symbol)" }
}

extension Settings {
    func hotkeyBinding(for action: HotkeyAction) -> HotkeyBinding {
        let sideKey = "hotkey.\(action.rawValue).side"
        let modKey = "hotkey.\(action.rawValue).modifier"
        let side = UserDefaults.standard.string(forKey: sideKey).flatMap(HotkeySide.init(rawValue:))
            ?? action.defaultBinding.side
        let modifier = UserDefaults.standard.string(forKey: modKey).flatMap(HotkeyModifier.init(rawValue:))
            ?? action.defaultBinding.modifier
        return HotkeyBinding(side: side, modifier: modifier)
    }

    func setHotkeyBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        UserDefaults.standard.set(binding.side.rawValue, forKey: "hotkey.\(action.rawValue).side")
        UserDefaults.standard.set(binding.modifier.rawValue, forKey: "hotkey.\(action.rawValue).modifier")
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
                if hotkeyBinding(for: a) == hotkeyBinding(for: b) && a.gesture == b.gesture {
                    conflicts.append((a, b))
                }
            }
        }
        return conflicts
    }
}
