@preconcurrency import AVFAudio
import Foundation

@MainActor
final class SystemSpeechEngine: NSObject, SpeechEngine, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var continuation: CheckedContinuation<Void, Error>?

    var displayName: String { "Apple system voice" }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String, speed: Double) async throws {
        stop()
        try Task.checkCancellation()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        if let selected = AVSpeechSynthesisVoice(identifier: voice) {
            utterance.voice = selected
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        try await withCheckedThrowingContinuation { continuation in
            self.activeUtterance = utterance
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        activeUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish(.failure(SpeechEngineError.interrupted))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        finish(.success(()))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        activeUtterance = nil
        finish(.failure(SpeechEngineError.interrupted))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
