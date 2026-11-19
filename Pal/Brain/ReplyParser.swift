import Foundation

/// Splits "spoken line\n---\non-screen detail" replies.
struct ParsedReply: Equatable {
    var spoken: String
    var detail: String
    /// The model has finished the spoken line (the separator arrived).
    var spokenComplete: Bool

    static func parse(_ raw: String, final: Bool) -> ParsedReply {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        if let sep = lines.firstIndex(where: { isSeparator($0) }) {
            let spoken = lines[..<sep].joined(separator: " ")
            let detail = lines[(sep + 1)...].joined(separator: "\n")
            return ParsedReply(spoken: plain(spoken), detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), spokenComplete: true)
        }
        guard final else {
            return ParsedReply(spoken: plain(text), detail: "", spokenComplete: false)
        }
        // The model ignored the format: speak the first sentence, show the rest.
        let (first, rest) = splitFirstSentence(text)
        return ParsedReply(spoken: plain(first), detail: rest, spokenComplete: true)
    }

    /// The whole reply as plain text (for copying).
    var copyText: String {
        detail.isEmpty ? spoken : "\(spoken)\n\n\(detail)"
    }

    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.allSatisfy { $0 == "-" || $0 == "—" || $0 == "–" }
    }

    private static func splitFirstSentence(_ text: String) -> (String, String) {
        let firstLine = text.components(separatedBy: "\n").first ?? text
        var end: String.Index?
        firstLine.enumerateSubstrings(in: firstLine.startIndex..., options: .bySentences) { _, range, _, stop in
            end = range.upperBound
            stop = true
        }
        guard let end, end < text.endIndex else { return (text, "") }
        return (String(text[..<end]), String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Strips markdown so it reads well and speaks cleanly.
    static func plain(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        for token in ["**", "__", "`", "#", "*"] { t = t.replacingOccurrences(of: token, with: "") }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
