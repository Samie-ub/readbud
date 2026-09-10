import Foundation
import Testing
@testable import ReadBudMac

@MainActor
private final class DelayedSpeechEngine: SpeechEngine {
    var displayName = "Test"
    var prepared = false
    var spoken: [String] = []
    var continuation: CheckedContinuation<Void, Never>?
    func prepare(_ texts: [String], voice: String, speed: Double) async throws {
        prepared = true
        // Deliberately non-cooperative, like an in-flight synchronous Core ML call.
        await withCheckedContinuation { continuation = $0 }
    }
    func finishPreparation() { continuation?.resume(); continuation = nil }
    func speak(_ text: String, voice: String, speed: Double) async throws { spoken.append(text) }
    func pause() {}
    func resume() {}
    func stop() {}
}

@MainActor
struct ReaderLifecycleTests {
    @Test func stoppedPreparationNeverStartsPlayback() async throws {
        let engine = DelayedSpeechEngine()
        let reader = ReaderModel(kokoroEngine: engine, systemEngine: engine, saved: nil, initialGeminiAPIKey: "", persistState: { _, _ in })
        reader.play()
        for _ in 0..<100 where !engine.prepared { await Task.yield() }
        #expect(engine.prepared)
        reader.stop()
        engine.finishPreparation()
        for _ in 0..<20 { await Task.yield() }
        #expect(engine.spoken.isEmpty)
        #expect(!reader.isPlaying)
        #expect(reader.activity == .ready)
    }

    @Test func newerImportWinsAndCancellationKeepsCurrentDocument() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.md")
        let second = directory.appendingPathComponent("second.md")
        try "First document.".write(to: first, atomically: true, encoding: .utf8)
        try "Second document.".write(to: second, atomically: true, encoding: .utf8)
        let engine = DelayedSpeechEngine()
        let reader = ReaderModel(kokoroEngine: engine, systemEngine: engine, saved: nil, initialGeminiAPIKey: "", persistState: { _, _ in })
        reader.cleanupMode = .basic
        reader.importSource(from: first)
        reader.importSource(from: second)
        for _ in 0..<200 where reader.isImporting { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reader.document.title == "second")
        #expect(!reader.isImporting)
        reader.importSource(from: first)
        reader.cancelImport()
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.document.title == "second")
        #expect(!reader.isImporting)
    }

    @Test func readNowCancelsAIAndCommitsBasicText() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).md")
        try "# Original\n\nThis is the complete document.".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let pipeline = ImportPipeline(localModels: { ["test"] }, localClean: { _, _ in
            try await Task.sleep(for: .seconds(60))
            return "Stale replacement."
        })
        let engine = DelayedSpeechEngine()
        let reader = ReaderModel(kokoroEngine: engine, systemEngine: engine, pipeline: pipeline, saved: nil, initialGeminiAPIKey: "",
                                 persistState: { _, _ in })
        reader.cleanupMode = .ollama
        reader.ollamaModel = "test"
        reader.importSource(from: file)
        for _ in 0..<200 where !reader.canReadNow { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reader.canReadNow)
        reader.readNow()
        #expect(!reader.isImporting)
        #expect(reader.document.text.contains("complete document"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!reader.document.text.contains("Stale"))
        reader.stop()
        engine.finishPreparation()
    }
}
