import Foundation

/// Recognises ticket references in commit messages and turns them into links.
///
/// Three common shapes are supported: `#123`, `PROJ-123` and `issue 123` (plus
/// a few synonyms). The URL is built from a user template with `{id}`,
/// `{number}` and `{key}` placeholders; a template that does not resolve to a
/// valid URL simply leaves that match as plain text.
enum TicketLinkDetector {
    struct Match {
        let range: Range<String.Index>
        let offset: Int
        let raw: String
        let id: String
        let number: String
        let key: String
    }

    private enum Kind {
        case hash
        case keyed
        case keyword
    }

    static func matches(in text: String) -> [Match] {
        let fullRange = NSRange(text.startIndex..., in: text)
        let nsText = text as NSString
        var found: [Match] = []

        let patterns: [(String, Kind)] = [
            (#"#(\d+)"#, .hash),
            (#"\b([A-Z][A-Z0-9]{1,9})-(\d+)\b"#, .keyed),
            (#"(?i)\b(issue|bug|ticket|fixes|fix|closes|close|resolves|resolve)\s*#?\s*(\d+)\b"#, .keyword)
        ]

        for (pattern, kind) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            for result in regex.matches(in: text, range: fullRange) {
                guard let range = Range(result.range, in: text) else { continue }
                let raw = nsText.substring(with: result.range)
                let number: String
                let key: String
                let id: String
                switch kind {
                case .hash:
                    guard result.numberOfRanges > 1,
                          let nRange = Range(result.range(at: 1), in: text) else { continue }
                    number = String(text[nRange])
                    key = ""
                    id = number
                case .keyed:
                    guard result.numberOfRanges > 2,
                          let kRange = Range(result.range(at: 1), in: text),
                          let nRange = Range(result.range(at: 2), in: text) else { continue }
                    key = String(text[kRange])
                    number = String(text[nRange])
                    id = "\(key)-\(number)"
                case .keyword:
                    guard result.numberOfRanges > 2,
                          let kRange = Range(result.range(at: 1), in: text),
                          let nRange = Range(result.range(at: 2), in: text) else { continue }
                    key = String(text[kRange]).uppercased()
                    number = String(text[nRange])
                    id = number
                }
                found.append(Match(
                    range: range,
                    offset: text.distance(from: text.startIndex, to: range.lowerBound),
                    raw: raw,
                    id: id,
                    number: number,
                    key: key
                ))
            }
        }

        // A longer match wins when patterns overlap (e.g. "fixes #123" is both
        // a keyword match and a bare "#123" hash match).
        found.sort { lhs, rhs in
            lhs.offset == rhs.offset
                ? lhs.raw.count > rhs.raw.count
                : lhs.offset < rhs.offset
        }
        var accepted: [Match] = []
        for candidate in found {
            if let last = accepted.last,
               candidate.range.lowerBound < last.range.upperBound {
                continue
            }
            accepted.append(candidate)
        }
        return accepted
    }

    static func url(match: Match, template: String) -> URL? {
        let effective = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? UIExtensionSettings.defaultTicketURLTemplate
            : template
        let resolved = effective
            .replacingOccurrences(of: "{id}", with: match.id)
            .replacingOccurrences(of: "{number}", with: match.number)
            .replacingOccurrences(of: "{key}", with: match.key)
        return URL(string: resolved)
    }

    /// The whole message with recognised references carrying a `.link` attribute.
    ///
    /// Built segment by segment rather than by converting `String.Index` into
    /// `AttributedString.Index`: the latter depends on Foundation conveniences
    /// that differ across SDKs, while concatenation is stable.
    static func attributed(_ text: String, template: String) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches(in: text) {
            if cursor < match.range.lowerBound {
                result += AttributedString(String(text[cursor..<match.range.lowerBound]))
            }
            var piece = AttributedString(String(text[match.range]))
            if let url = self.url(match: match, template: template) {
                piece.link = url
            }
            result += piece
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor..<text.endIndex]))
        }
        return result
    }
}
