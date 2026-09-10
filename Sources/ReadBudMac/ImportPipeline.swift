import Foundation

struct ImportedText: Sendable {
    let title: String
    let text: String
}

enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, basic, ollama, gemini
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic · local first"
        case .basic: "Fast · no AI"
        case .ollama: "Local AI · Ollama"
        case .gemini: "Cloud AI · Gemini (articles)"
        }
    }
}

struct CleanupSettings: Sendable {
    let mode: CleanupMode
    let model: String
    let apiKey: String
    let budget: Duration
}

struct CleanupRoute: Sendable {
    enum Provider: Sendable { case basic, ollama, gemini }
    let provider: Provider
    let reason: String

    static func decide(mode: CleanupMode, source: URL, text: String) -> Self {
        switch mode {
        case .basic: return Self(provider: .basic, reason: "Fast cleanup selected")
        case .ollama: return Self(provider: .ollama, reason: "Local AI explicitly selected")
        case .gemini:
            return source.isFileURL
                ? Self(provider: .basic, reason: "Gemini is limited to article URLs")
                : Self(provider: .gemini, reason: "Gemini explicitly selected")
        case .automatic:
            // Markdown and plain text already have structured, deterministic extraction.
            if source.isFileURL && source.pathExtension.lowercased() != "pdf" {
                return Self(provider: .basic, reason: "Readable file: formatting cleanup needs no model")
            }
            // Avoid a long-document rewrite. Only request AI for evident extraction debris.
            let noisyLines = text.split(separator: "\n").filter {
                $0.contains("�") || $0.contains("| |") || $0.contains("   ")
            }.count
            if noisyLines >= 3 && text.count <= 8_000 {
                return Self(provider: .ollama, reason: "Short extraction with formatting debris")
            }
            return Self(provider: .basic, reason: "Local extraction is ready to read")
        }
    }
}

struct CleanupOutcome: Sendable {
    let document: ReaderDocument
    let notice: String?
}

/// Owns extraction, normalization, routing, and segmentation away from the UI actor.
/// Providers never mutate reader state; the reader commits only the active import's result.
actor ImportPipeline {
    typealias Progress = @Sendable (String) async -> Void
    typealias Cleaner = @Sendable (String, String) async throws -> String
    private let localClean: Cleaner
    private let localModels: @Sendable () async throws -> [String]

    init(localModels: @escaping @Sendable () async throws -> [String] = {
        try await OllamaCleanupClient.models()
    }, localClean: @escaping Cleaner = { text, model in
        try await OllamaCleanupClient.clean(text, model: model)
    }) {
        self.localClean = localClean
        self.localModels = localModels
    }

    func extract(from url: URL, trace: WebArticleImporter.TraceHandler? = nil) async throws -> ReaderDocument {
        try Task.checkCancellation()
        let raw = try await (url.isFileURL
            ? DocumentImporter.load(from: url)
            : WebArticleImporter.load(from: url, onTrace: trace))
        try Task.checkCancellation()
        let basic = ReadingTextCleaner.clean(raw.text)
        guard !basic.isEmpty else { throw DocumentImportError.empty }
        return ReaderDocument.make(title: raw.title, text: basic)
    }

    func cleanup(_ basic: ReaderDocument, source: URL, settings: CleanupSettings,
                 progress: @escaping Progress) async throws -> CleanupOutcome {
        let route = CleanupRoute.decide(mode: settings.mode, source: source, text: basic.text)
        await progress(route.reason)
        guard route.provider != .basic else { return CleanupOutcome(document: basic, notice: nil) }
        do {
            // One wall-clock budget for discovery + every section, not a timeout per section.
            let result = try await withDeadline(settings.budget) { [localClean, localModels] in
                switch route.provider {
                case .basic: return basic.text
                case .ollama:
                    await progress("Connecting to local AI…")
                    let available = try await localModels()
                    let model = settings.model.isEmpty ? available.first ?? "" : settings.model
                    guard available.contains(model) else {
                        throw OllamaCleanupClient.CleanupError(message: "Select an installed local text model in Settings.")
                    }
                    return try await Self.cleanSections(basic.text, model: model, cleaner: localClean, progress: progress)
                case .gemini:
                    await progress("Cleaning article with Gemini…")
                    let result = try await GeminiCleanupClient.clean(text: basic.text, title: basic.title, apiKey: settings.apiKey)
                    guard !result.wasTruncated else {
                        throw OllamaCleanupClient.CleanupError(message: "Article exceeds the cloud cleanup limit.")
                    }
                    return result.text
                }
            }
            try Task.checkCancellation()
            return CleanupOutcome(document: ReaderDocument.make(title: basic.title, text: result), notice: nil)
        } catch {
            try Task.checkCancellation()
            return CleanupOutcome(document: basic, notice: "Using fast cleanup. \(error.localizedDescription)")
        }
    }

    static func cleanSections(_ text: String, model: String, cleaner: Cleaner,
                              progress: @escaping Progress) async throws -> String {
        let sections = ReadingTextCleaner.chunks(text, limit: 1_000)
        var output: [String] = []
        for (index, section) in sections.enumerated() {
            try Task.checkCancellation()
            await progress("Cleaning section \(index + 1) of \(sections.count)…")
            output.append(try await cleaner(section, model))
        }
        try Task.checkCancellation()
        return output.joined(separator: "\n\n")
    }
}

struct CleanupDeadlineError: LocalizedError {
    var errorDescription: String? { "AI reached its time limit; the full document is ready to read." }
}

func withDeadline<T: Sendable>(_ duration: Duration,
                             operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw CleanupDeadlineError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}
