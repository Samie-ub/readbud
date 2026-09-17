import Foundation

struct ReaderSentence: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    let text: String
}

struct ReaderDocument: Codable, Equatable, Sendable {
    var title: String
    var text: String
    var sentences: [ReaderSentence]

    static let welcome = ReaderDocument.make(
        title: "Welcome to ReadBud",
        text: """
        The way we read is changing.

        For centuries, reading demanded our full visual attention. Today, many of us spend the day moving between screens, errands, and ideas. Listening makes it possible to keep learning while our eyes and hands are occupied.

        ReadBud turns long documents into a calm, focused listening experience. It follows the text sentence by sentence, remembers where you stopped, and lets you move through an article at your own pace. Click any sentence to begin from that point.
        """
    )

    static func make(title: String, text: String) -> ReaderDocument {
        ReaderDocument(title: title, text: text, sentences: TextSegmenter.sentences(from: text))
    }
}

enum SpeechEngineKind: String, CaseIterable, Identifiable, Codable, Sendable {
    // Retained only so previously saved ReadBud state can be decoded after the
    // Kokoro engine is removed. All new playback uses the Apple voice engine.
    case kokoro
    case system

    var id: String { rawValue }
    var label: String {
        switch self {
        case .kokoro: "Apple system voice"
        case .system: "Apple system voice"
        }
    }
}

enum ReaderActivity: Equatable {
    case ready
    case preparing
    case reading
    case paused
    case failed(String)

    var label: String {
        switch self {
        case .ready: "Ready to listen"
        case .preparing: "Preparing neural voice…"
        case .reading: "Reading aloud"
        case .paused: "Paused"
        case .failed: "Playback stopped"
        }
    }
}

enum DebugLogLevel: String, Codable {
    case info
    case success
    case warning
    case error
}

struct DebugLogEntry: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let level: DebugLogLevel
    let message: String
}
