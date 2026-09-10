import Foundation
import Testing
@testable import ReadBudMac

struct CleanupTests {
    @Test func markdownKeepsMeaning() {
        let input = "# Chapter One\n\n- **Price:** $12.50\n- [Read more](https://example.com)\n\n```swift\nlet count = 42\n```\n\n---"
        let result = ReadingTextCleaner.clean(input)
        #expect(result.contains("Chapter One"))
        #expect(result.contains("Price: $12.50"))
        #expect(result.contains("Read more"))
        #expect(result.contains("let count = 42"))
        #expect(!result.contains("https://"))
        #expect(!result.contains("```"))
        #expect(!result.contains("**"))
    }

    @Test func chunkingPreservesEntireLongUnicodeDocument() {
        let input = String(repeating: "A paragraph about café ☕️.\n\n", count: 500) + String(repeating: "界", count: 7_001)
        let chunks = ReadingTextCleaner.chunks(input)
        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 3_000 })
    }

    @Test func proseAndMathSurviveBasicCleanup() {
        let input = "The value is -42. Costs rose 5%.\n\nx * y = 12; snake_case stays."
        #expect(ReadingTextCleaner.clean(input) == input)
    }
}
