import Foundation

/// Conservative formatting cleanup; retains prose, numbers, and code contents.
enum ReadingTextCleaner {
    static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let replacements: [(String, String)] = [
            (#"(?m)^\s*(```|~~~)[^\n]*$"#, ""),
            (#"!\[([^\]]*)\]\([^\n)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\([^\n)]*\)"#, "$1"),
            (#"(?m)^ {0,3}#{1,6}\s+(.+?)(?:\s+#+)?$"#, "$1"),
            (#"(?m)^\s*>\s?"#, ""),
            (#"(?m)^\s*[-+*]\s+(?:\[[ xX]\]\s*)?"#, ""),
            (#"(?m)^\s*(?:[-*_]\s*){3,}$"#, ""),
            (#"(?m)^\s*\|?[ :\-]+\|[| :\-]*$"#, ""),
            (#"\*\*([^\n]+?)\*\*"#, "$1"),
            (#"__([^\n]+?)__"#, "$1"),
            (#"(?<!\w)\*([^*\n]+)\*(?!\w)"#, "$1"),
            (#"(?<!\w)_([^_\n]+)_(?!\w)"#, "$1"),
            (#"~~([^\n]+?)~~"#, "$1"),
            (#"`([^`\n]+)`"#, "$1"),
            (#"[\u200B\uFEFF]"#, ""),
            (#"[ \t]+\n"#, "\n"),
            (#"\n{3,}"#, "\n\n")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every character is included, even when a paragraph exceeds the chunk size.
    static func chunks(_ text: String, limit: Int = 3_000) -> [String] {
        precondition(limit > 0)
        var remaining = text[...]
        var result: [String] = []
        while !remaining.isEmpty {
            var end = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex) ?? remaining.endIndex
            if end != remaining.endIndex {
                let candidate = remaining[..<end]
                if let boundary = candidate.lastIndex(where: { $0.isWhitespace }),
                   candidate.distance(from: candidate.startIndex, to: boundary) > limit / 2 {
                    end = remaining.index(after: boundary)
                }
            }
            result.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return result
    }
}
