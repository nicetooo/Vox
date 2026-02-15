import Foundation
import NaturalLanguage

/// Translates text with auto-flip: English ↔ Chinese.
/// Uses Google Translate free endpoint (no API key needed).
class TranslationService {

    /// Translation result with language info
    struct Result {
        let text: String
        let sourceLang: String
        let targetLang: String
    }

    /// Translate text. Calls completion on a background thread.
    func translate(_ text: String, completion: @escaping (String?) -> Void) {
        let result = translateWithInfo(text)
        completion(result?.text)
    }

    /// Translate text, returning full result with language info.
    func translateWithInfo(_ text: String) -> Result? {
        let sourceLang = detectLanguage(text)
        let targetLang: String

        if sourceLang == "zh" {
            targetLang = "en"
        } else {
            targetLang = "zh-CN"
        }

        log("Translation: \(sourceLang) → \(targetLang)")

        if let translated = googleTranslate(text, to: targetLang) {
            return Result(text: translated, sourceLang: sourceLang, targetLang: targetLang)
        }
        return nil
    }

    // MARK: - Language Detection

    private func detectLanguage(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else {
            return "en" // Default to English
        }

        switch language {
        case .simplifiedChinese, .traditionalChinese:
            return "zh"
        default:
            return language.rawValue
        }
    }

    // MARK: - Google Translate (free endpoint, no API key)

    private func googleTranslate(_ text: String, to targetLang: String) -> String? {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(targetLang)&dt=t&q=\(encoded)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var result: String?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard let data = data, error == nil else {
                log("Translation request failed: \(error?.localizedDescription ?? "unknown")")
                return
            }

            // Response format: [[["translated text","original text",...],...],...]]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let sentences = json.first as? [Any] {
                var translated = ""
                for sentence in sentences {
                    if let parts = sentence as? [Any],
                       let text = parts.first as? String {
                        translated += text
                    }
                }
                if !translated.isEmpty {
                    result = translated
                }
            }
        }

        task.resume()
        semaphore.wait()
        return result
    }
}
