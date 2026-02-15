import Foundation

// MARK: - Model Info

struct WhisperModelInfo {
    let name: String         // HuggingFace repo name
    let displayName: String  // User-friendly name
    let size: String         // Approximate download size
}

// MARK: - Settings (UserDefaults backed)

class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // MARK: - Popular Whisper Models

    static let popularModels: [WhisperModelInfo] = [
        WhisperModelInfo(name: "mlx-community/whisper-large-v3-turbo", displayName: "Large V3 Turbo (recommended)", size: "1.6 GB"),
        WhisperModelInfo(name: "mlx-community/whisper-large-v3-mlx", displayName: "Large V3 (best quality)", size: "3.1 GB"),
        WhisperModelInfo(name: "mlx-community/whisper-medium-mlx", displayName: "Medium", size: "1.5 GB"),
        WhisperModelInfo(name: "mlx-community/whisper-small-mlx", displayName: "Small", size: "460 MB"),
        WhisperModelInfo(name: "mlx-community/whisper-base-mlx", displayName: "Base", size: "140 MB"),
        WhisperModelInfo(name: "mlx-community/whisper-tiny", displayName: "Tiny (fastest)", size: "75 MB"),
        WhisperModelInfo(name: "mlx-community/distil-whisper-large-v3", displayName: "Distil Large V3 (fast+good)", size: "1.5 GB"),
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
    /// zh-Hans and zh-Hant both map to "zh" for Whisper.
    var whisperLanguageArg: String? {
        let langs = selectedLanguages
        // Map to Whisper codes and deduplicate
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
        get { defaults.string(forKey: "whisperModel") ?? "mlx-community/whisper-large-v3-turbo" }
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

    // MARK: - Model Cache Management

    // MARK: - Python Path Discovery

    /// Find python3 binary by checking common install locations
    static let pythonPath: String = {
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        let found = candidates.first { FileManager.default.fileExists(atPath: $0) }
        if let found = found {
            log("Python found: \(found)")
        } else {
            log("WARNING: Python not found in any known location!")
        }
        return found ?? "/usr/bin/python3"
    }()

    /// Find mlx_whisper binary — look in same bin dir as python3, then common locations
    static let mlxWhisperPath: String = {
        // First: check same directory as python3
        let pythonBinDir = (pythonPath as NSString).deletingLastPathComponent
        let sameDirPath = pythonBinDir + "/mlx_whisper"
        if FileManager.default.fileExists(atPath: sameDirPath) {
            log("mlx_whisper found: \(sameDirPath)")
            return sameDirPath
        }
        // Fallback: check common locations
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/mlx_whisper",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/mlx_whisper",
            "/opt/homebrew/bin/mlx_whisper",
            "/usr/local/bin/mlx_whisper",
        ]
        let found = candidates.first { FileManager.default.fileExists(atPath: $0) }
        if let found = found {
            log("mlx_whisper found: \(found)")
        } else {
            log("WARNING: mlx_whisper not found! Voice input won't work.")
        }
        return found ?? "/usr/local/bin/mlx_whisper"
    }()

    /// Scan HuggingFace cache for downloaded whisper models
    static func cachedModelNames() -> Set<String> {
        let cacheDir = NSHomeDirectory() + "/.cache/huggingface/hub"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cacheDir) else { return [] }

        var models = Set<String>()
        for entry in entries {
            guard entry.hasPrefix("models--") else { continue }
            let cleaned = entry.replacingOccurrences(of: "models--", with: "")
            let name = cleaned.replacingOccurrences(of: "--", with: "/")
            // Only include whisper models
            if name.lowercased().contains("whisper") {
                models.insert(name)
            }
        }
        return models
    }

    /// Download progress info
    struct DownloadProgress {
        let percent: Double    // 0.0 - 1.0
        let fileName: String
        let message: String
    }

    /// Download a model from HuggingFace in background, reporting real byte-level progress
    static func downloadModel(_ modelName: String, onProgress: @escaping (DownloadProgress) -> Void, onComplete: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Settings.pythonPath)
            process.arguments = [
                "-c",
                """
                import sys, os, time

                # === Monkeypatch tqdm BEFORE importing huggingface_hub ===
                # This lets us capture real byte-level download progress
                _completed = [0]       # bytes of fully downloaded files
                _total_bytes = [0]     # total model size
                _total_str = ['']      # formatted total size string
                _cur_file = ['']       # current file being downloaded
                _last_t = [0.0]        # throttle: last report time

                def _fmt(b):
                    if b >= 1_000_000_000: return f'{b/1_000_000_000:.2f} GB'
                    if b >= 1_000_000: return f'{b/1_000_000:.0f} MB'
                    return f'{b/1_000:.0f} KB'

                try:
                    import tqdm, tqdm.auto
                    _Orig = tqdm.auto.tqdm

                    class _PT(_Orig):
                        def __init__(self, *a, **kw):
                            kw['disable'] = False
                            super().__init__(*a, **kw)
                        def update(self, n=1):
                            r = super().update(n)
                            tb = _total_bytes[0]
                            if self.total and self.total > 50000 and tb > 0:
                                now = time.time()
                                if now - _last_t[0] < 0.3:
                                    return r
                                _last_t[0] = now
                                done = _completed[0] + self.n
                                pct = min(99, int(done * 100 / tb))
                                print(f'PROGRESS:{pct}:{_fmt(done)} / {_total_str[0]}:{_cur_file[0]}', flush=True)
                            return r

                    tqdm.auto.tqdm = _PT
                    tqdm.tqdm = _PT
                except Exception:
                    pass

                os.environ.pop('HF_HUB_DISABLE_PROGRESS_BARS', None)

                from huggingface_hub import HfApi, hf_hub_download

                model = '\(modelName)'
                api = HfApi()

                try:
                    info = api.model_info(model, files_metadata=True)
                except Exception as e:
                    print(f'ERROR:{e}', flush=True)
                    sys.exit(1)

                file_list = []
                for f in info.siblings:
                    size = getattr(f, 'size', None) or 0
                    file_list.append((f.rfilename, size))

                _total_bytes[0] = sum(s for _, s in file_list)
                _total_str[0] = _fmt(_total_bytes[0])

                print(f'PROGRESS:0:0 / {_total_str[0]}:Preparing...', flush=True)

                for i, (fname, fsize) in enumerate(file_list):
                    _cur_file[0] = fname
                    try:
                        hf_hub_download(model, fname)
                    except Exception as e:
                        print(f'ERROR:{e}', flush=True)
                        sys.exit(1)
                    _completed[0] += fsize
                    pct = int(_completed[0] * 100 / _total_bytes[0]) if _total_bytes[0] > 0 else 100
                    print(f'PROGRESS:{pct}:{_fmt(_completed[0])} / {_total_str[0]}:{fname} done', flush=True)

                print(f'PROGRESS:100:{_total_str[0]} / {_total_str[0]}:Complete', flush=True)
                print('DONE', flush=True)
                """
            ]

            // Ensure HOME and cache paths are correct
            var env = ProcessInfo.processInfo.environment
            env["HOME"] = NSHomeDirectory()
            env["HF_HOME"] = NSHomeDirectory() + "/.cache/huggingface"
            process.environment = env

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Read stdout line by line for progress
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("PROGRESS:") {
                        // Format: PROGRESS:percent:sizeInfo:description
                        let parts = trimmed.dropFirst("PROGRESS:".count).components(separatedBy: ":")
                        if parts.count >= 3,
                           let pct = Double(parts[0]) {
                            let sizeInfo = parts[1]
                            let desc = parts[2...].joined(separator: ":")
                            let msg = "\(sizeInfo) — \(desc)"
                            DispatchQueue.main.async {
                                onProgress(DownloadProgress(percent: pct / 100.0, fileName: desc, message: msg))
                            }
                        }
                    }
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                DispatchQueue.main.async {
                    onProgress(DownloadProgress(percent: 0, fileName: "", message: "Error: \(error.localizedDescription)"))
                    onComplete(false)
                }
                return
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil

            let success = process.terminationStatus == 0
            if !success {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                log("Model download failed: \(modelName) — \(errStr.prefix(300))")
            } else {
                log("Model download success: \(modelName)")
            }

            DispatchQueue.main.async {
                onComplete(success)
            }
        }
    }
    /// Delete a downloaded model from the HuggingFace cache
    static func deleteModel(_ modelName: String) -> Bool {
        let cacheDir = NSHomeDirectory() + "/.cache/huggingface/hub"
        let dirName = "models--" + modelName.replacingOccurrences(of: "/", with: "--")
        let fullPath = cacheDir + "/" + dirName

        let fm = FileManager.default
        guard fm.fileExists(atPath: fullPath) else {
            log("Delete model: directory not found: \(fullPath)")
            return false
        }

        do {
            try fm.removeItem(atPath: fullPath)
            log("Delete model: removed \(modelName) (\(fullPath))")
            return true
        } catch {
            log("Delete model: failed to remove \(modelName) — \(error)")
            return false
        }
    }

    /// Get approximate size of a cached model
    static func cachedModelSize(_ modelName: String) -> String {
        let cacheDir = NSHomeDirectory() + "/.cache/huggingface/hub"
        let dirName = "models--" + modelName.replacingOccurrences(of: "/", with: "--")
        let fullPath = cacheDir + "/" + dirName

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: fullPath) else { return "?" }

        var totalSize: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let filePath = fullPath + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? UInt64 {
                totalSize += size
            }
        }

        if totalSize > 1_000_000_000 {
            return String(format: "%.1f GB", Double(totalSize) / 1_000_000_000)
        } else {
            return String(format: "%.0f MB", Double(totalSize) / 1_000_000)
        }
    }
}

struct LanguageOption {
    let code: String
    let name: String
}
