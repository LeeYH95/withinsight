import Foundation

enum NotesWebLink {
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              !text.contains("\\"),
              text.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              let url = URL(string: text),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return url
    }

    static func destination(from value: Any?) -> URL? {
        if let value = value as? URL { return url(from: value.absoluteString) }
        if let value = value as? String { return url(from: value) }
        return nil
    }

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var cleaned = String.UnicodeScalarView()
        for scalar in title.unicodeScalars {
            // Keep joiners used by emoji and scripts while discarding invisible
            // formatting controls such as bidirectional overrides.
            let category = scalar.properties.generalCategory
            if category == .control || (category == .format && scalar.value != 0x200C && scalar.value != 0x200D) {
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        let normalized = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limited = String(normalized.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVisibleContent = limited.unicodeScalars.contains {
            !$0.properties.isDefaultIgnorableCodePoint &&
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return hasVisibleContent ? limited : nil
    }
}
