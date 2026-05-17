import Foundation

/// Lookup a localized string by key.
///
/// `L("foo.bar")` → returns the translation from the matching .lproj/Localizable.strings
/// in the app bundle. If the key isn't found, falls back to the key itself
/// (visibly broken UI is better than a silent default in dev).
///
/// `L("foo.with_arg", "x", 7)` → format string with args, mirroring
/// `String(format:arguments:)`.
@inline(__always)
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    if args.isEmpty { return format }
    return String(format: format, locale: Locale.current, arguments: args)
}
