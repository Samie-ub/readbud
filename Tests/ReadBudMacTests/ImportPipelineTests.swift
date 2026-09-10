import Foundation
import Testing
@testable import ReadBudMac

struct ImportPipelineTests {
    private let markdownURL = URL(fileURLWithPath: "/tmp/example.md")

    @Test func automaticMarkdownNeverCallsAI() async throws {
        let pipeline = ImportPipeline(localModels: {
            Issue.record("Automatic Markdown must not contact Ollama")
            return []
        }, localClean: { _, _ in
            Issue.record("Automatic Markdown must not invoke generation")
            return ""
        })
        let document = ReaderDocument.make(title: "Example", text: "A readable document.")
        let result = try await pipeline.cleanup(document, source: markdownURL,
            settings: CleanupSettings(mode: .automatic, model: "", apiKey: "", budget: .seconds(1)), progress: { _ in })
        #expect(result.document == document)
        #expect(result.notice == nil)
    }

    @Test func deadlineCancelsSlowAIAndPreservesWholeDocument() async throws {
        let pipeline = ImportPipeline(localModels: { ["test"] }, localClean: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return "This should never be committed."
        })
        let document = ReaderDocument.make(title: "Example", text: String(repeating: "Full content. ", count: 300))
        let start = ContinuousClock.now
        let result = try await pipeline.cleanup(document, source: markdownURL,
            settings: CleanupSettings(mode: .ollama, model: "test", apiKey: "", budget: .milliseconds(40)), progress: { _ in })
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(result.document == document)
        #expect(result.notice?.contains("time limit") == true)
    }

    @Test func cancellationPropagatesInsteadOfCommittingFallback() async throws {
        let pipeline = ImportPipeline(localModels: { ["test"] }, localClean: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return "No"
        })
        let task = Task {
            try await pipeline.cleanup(ReaderDocument.make(title: "Test", text: "Keep this."), source: markdownURL,
                settings: CleanupSettings(mode: .ollama, model: "test", apiKey: "", budget: .seconds(60)), progress: { _ in })
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Canceled imports must not return a document")
        } catch is CancellationError { }
    }

    @Test func laterSectionFailureNeverCommitsPartialRewrite() async throws {
        let pipeline = ImportPipeline(localModels: { ["test"] }, localClean: { text, _ in
            if text.contains("FAIL") { throw CleanupDeadlineError() }
            return "AI replacement"
        })
        let document = ReaderDocument.make(title: "Test", text: String(repeating: "First section. ", count: 100) + "FAIL last section.")
        let result = try await pipeline.cleanup(document, source: markdownURL,
            settings: CleanupSettings(mode: .ollama, model: "test", apiKey: "", budget: .seconds(2)), progress: { _ in })
        #expect(result.document == document)
        #expect(result.notice != nil)
    }

    @Test func cloudRouteRequiresExplicitModeAndURL() {
        let article = URL(string: "https://example.com/article")!
        #expect(CleanupRoute.decide(mode: .automatic, source: article, text: "Clean article").provider == .basic)
        #expect(CleanupRoute.decide(mode: .gemini, source: markdownURL, text: "Text").provider == .basic)
        #expect(CleanupRoute.decide(mode: .gemini, source: article, text: "Text").provider == .gemini)
    }

    @Test func longUnpunctuatedTextHasBoundedSpeechSegments() {
        let text = String(repeating: "readable words ", count: 2_000)
        let sentences = TextSegmenter.sentences(from: text)
        #expect(sentences.count > 1)
        #expect(sentences.allSatisfy { $0.text.count <= 600 })
        #expect(sentences.map(\.text).joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func largeMarkdownImportBenchmark() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("readbud-test-\(UUID()).md")
        let text = String(repeating: "# A useful section\n\nHere is **readable prose** with a price of $12.50.\n\n", count: 4_000)
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let start = ContinuousClock.now
        let document = try await ImportPipeline().extract(from: file)
        print("ReadBud benchmark: \(text.utf8.count) Markdown bytes → \(document.sentences.count) segments in \(start.duration(to: .now))")
        #expect(!document.text.contains("**"))
        #expect(document.text.components(separatedBy: "$12.50").count - 1 == 4_000)
    }
}
