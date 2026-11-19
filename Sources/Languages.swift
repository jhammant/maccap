import Foundation

/// The language a call is in: what live transcription listens for. Apple's
/// transcriber hears one language at a time and can't tell which one is
/// spoken, so the person picks it: in the menu bar for the next call, or in
/// the live window mid-call. The last pick is kept for the next call.
enum CallLanguage {
    /// What a call starts in: the last language picked, else
    /// `live_notes_locale`, else nil (the Mac's own language).
    static func initial(picked: String?, configured: String?) -> String? {
        picked ?? configured
    }

    /// A locale's full name in the Mac's language: "Spanish (Spain)".
    static func name(_ identifier: String, in display: Locale = .current) -> String {
        display.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Just the language: "Spanish".
    static func shortName(_ identifier: String, in display: Locale = .current) -> String {
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return display.localizedString(forLanguageCode: code) ?? identifier
    }

    /// The supported locale for `identifier`: the same one ("es-ES" is
    /// es_ES), else one of the same language, preferring the Mac's region.
    static func match(_ identifier: String, in supported: [String], region: String? = Locale.current.region?.identifier) -> String? {
        let key = identifier.replacingOccurrences(of: "-", with: "_")
        if supported.contains(key) { return key }
        let language = Locale(identifier: key).language.languageCode?.identifier
        let same = supported.filter { Locale(identifier: $0).language.languageCode?.identifier == language }
        if let region, let local = same.first(where: { Locale(identifier: $0).region?.identifier == region }) {
            return local
        }
        return same.first
    }

    /// The languages to offer. First the one in use, the ones picked before
    /// and the ones this Mac is set to; then the rest, by name.
    static func menu(supported: [String], current: String?, recent: [String] = [],
                     preferred: [String] = Locale.preferredLanguages,
                     region: String? = Locale.current.region?.identifier,
                     display: Locale = .current) -> (top: [String], more: [String]) {
        var top: [String] = []
        for identifier in [current].compactMap({ $0 }) + recent + preferred {
            if let id = match(identifier, in: supported, region: region), !top.contains(id) { top.append(id) }
        }
        let more = supported.filter { !top.contains($0) }
            .sorted { name($0, in: display).localizedStandardCompare(name($1, in: display)) == .orderedAscending }
        return (top, more)
    }
}
