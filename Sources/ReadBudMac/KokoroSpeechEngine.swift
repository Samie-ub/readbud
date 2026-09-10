@preconcurrency import AVFAudio
import Foundation
import KokoroCoreML

private struct NativeAudio: Sendable {
    let samples: [Float]
}

/// Core ML is synchronous: actor isolation prevents old/new playback jobs from
/// synthesizing concurrently. Cancellation is checked before and after each call.
private actor KokoroSynthesisWorker {
    private var engine: KokoroEngine?

    func synthesize(text: String, voice: String, speed: Double) throws -> NativeAudio {
        try Task.checkCancellation()
        if engine == nil {
            if !KokoroEngine.isDownloaded { try KokoroEngine.download() }
            try Task.checkCancellation()
            engine = try KokoroEngine(modelDirectory: KokoroEngine.defaultModelDirectory)
        }
        try Task.checkCancellation()
        let result = try engine!.synthesize(text: text, voice: voice, speed: Float(speed))
        try Task.checkCancellation()
        return NativeAudio(samples: result.samples)
    }

    func release() {
        guard !Task.isCancelled else { return }
        engine = nil
    }
}

@MainActor
final class KokoroSpeechEngine: SpeechEngine {
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let worker = KokoroSynthesisWorker()
    private var continuation: CheckedContinuation<Void, Error>?
    private var prepared: (key: String, audio: NativeAudio)?
    private var generation = UUID()
    private var bufferID = UUID()
    private var idleReleaseTask: Task<Void, Never>?

    var displayName: String { "Kokoro · Core ML" }

    init() {
        audioEngine.attach(player)
        audioEngine.connect(player, to: audioEngine.mainMixerNode, format: KokoroEngine.audioFormat)
    }

    func prepare(_ texts: [String], voice: String, speed: Double) async throws {
        guard let text = texts.first else { return }
        idleReleaseTask?.cancel()
        let key = "\(voice)|\(speed)|\(text)"
        if prepared?.key == key { return }
        let id = generation
        let audio = try await worker.synthesize(text: text, voice: voice, speed: speed)
        try Task.checkCancellation()
        guard id == generation else { throw SpeechEngineError.interrupted }
        prepared = (key, audio)
    }

    func speak(_ text: String, voice: String, speed: Double) async throws {
        try await prepare([text], voice: voice, speed: speed)
        try Task.checkCancellation()
        guard let audio = prepared?.audio else { throw SpeechEngineError.invalidAudio }
        prepared = nil
        try await play(samples: audio.samples)
    }

    func pause() { player.pause() }
    func resume() { player.play() }

    func stop() {
        generation = UUID()
        bufferID = UUID()
        player.stop()
        audioEngine.stop()
        prepared = nil
        finish(.failure(SpeechEngineError.interrupted))
        scheduleRelease()
    }

    private func play(samples: [Float]) async throws {
        try Task.checkCancellation()
        guard !samples.isEmpty,
              let buffer = KokoroEngine.makePCMBuffer(from: samples, format: KokoroEngine.audioFormat) else {
            throw SpeechEngineError.invalidAudio
        }
        let id = UUID()
        bufferID = id
        if !audioEngine.isRunning { try audioEngine.start() }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.bufferID == id else { return }
                    self.audioEngine.pause()
                    self.finish(.success(()))
                    self.scheduleRelease()
                }
            }
            player.play()
        }
    }

    private func scheduleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task { [worker] in
            do {
                try await Task.sleep(for: .seconds(30))
                try Task.checkCancellation()
                await worker.release()
            } catch { }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
