import Foundation

@MainActor
protocol SpeechEngine: AnyObject {
    var displayName: String { get }
    func prepare(_ texts: [String], voice: String, speed: Double) async throws
    func speak(_ text: String, voice: String, speed: Double) async throws
    func pause()
    func resume()
    func stop()
}

extension SpeechEngine {
    func prepare(_ texts: [String], voice: String, speed: Double) async throws {}
}

enum SpeechEngineError: LocalizedError {
    case nativeUnavailable(String)
    case invalidAudio
    case interrupted

    var errorDescription: String? {
        switch self {
        case .nativeUnavailable(let reason): reason
        case .invalidAudio: "The native engine returned invalid audio."
        case .interrupted: "Playback was interrupted."
        }
    }
}
