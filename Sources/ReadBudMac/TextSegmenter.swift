import Foundation
import NaturalLanguage

enum TextSegmenter {
    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: #"(?<!\n)\n(?!\n)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentences(from value: String) -> [ReaderSentence] {
        let normalized = normalize(value)
        guard !normalized.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized
        var result: [ReaderSentence] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            let sentence = normalized[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                // Punctuation-free imports must not become one enormous synthesis request.
                for chunk in ReadingTextCleaner.chunks(sentence, limit: 600) {
                    let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { result.append(ReaderSentence(id: result.count, text: text)) }
                }
            }
            return true
        }
        return result
    }
}

