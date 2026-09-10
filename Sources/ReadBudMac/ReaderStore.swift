import Foundation

struct SavedReaderState: Codable, Sendable {
    let document: ReaderDocument
    let sentenceIndex: Int
    let speed: Double
    let voiceID: String
    var engineKind: SpeechEngineKind? = nil
}

enum ReaderStore {
    static let writer = Writer()
    private static let legacyKey = "readbud.reader-state.v1"
    private static let documentKey = "readbud.document.v2"
    private static let progressKey = "readbud.progress.v2"

    private struct Progress: Codable {
        let sentenceIndex: Int
        let speed: Double
        let voiceID: String
        let engineKind: SpeechEngineKind?
    }

    static func persist(_ state: SavedReaderState, _ revision: UUID) async {
        await writer.save(state, revision: revision)
    }

    static func load() -> SavedReaderState? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: documentKey),
           let document = try? JSONDecoder().decode(ReaderDocument.self, from: data),
           let progressData = defaults.data(forKey: progressKey),
           let progress = try? JSONDecoder().decode(Progress.self, from: progressData) {
            return SavedReaderState(document: document, sentenceIndex: progress.sentenceIndex,
                                    speed: progress.speed, voiceID: progress.voiceID, engineKind: progress.engineKind)
        }
        guard let legacy = defaults.data(forKey: legacyKey) else { return nil }
        return try? JSONDecoder().decode(SavedReaderState.self, from: legacy)
    }

    actor Writer {
        private var savedRevision: UUID?

        func save(_ state: SavedReaderState, revision: UUID) {
            let defaults = UserDefaults.standard
            // The large document is encoded once per import, off the main actor.
            if revision != savedRevision {
                guard let data = try? JSONEncoder().encode(state.document) else { return }
                defaults.set(data, forKey: documentKey)
                savedRevision = revision
            }
            let progress = Progress(sentenceIndex: state.sentenceIndex, speed: state.speed,
                                    voiceID: state.voiceID, engineKind: state.engineKind)
            guard let data = try? JSONEncoder().encode(progress) else { return }
            defaults.set(data, forKey: progressKey)
            defaults.removeObject(forKey: legacyKey)
        }
    }
}
