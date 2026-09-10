import AVFAudio
import Combine
import Foundation

@MainActor
final class ReaderModel: ObservableObject {
    @Published private(set) var document: ReaderDocument
    @Published private(set) var activeIndex: Int
    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var activity: ReaderActivity = .ready
    @Published private(set) var isImporting = false
    @Published var speed: Double
    @Published var selectedVoiceID: String
    @Published var engineKind: SpeechEngineKind = .kokoro
    @Published var importError: String?
    @Published private(set) var debugLog: [DebugLogEntry] = []
    @Published private(set) var activeWordIndex = 0
    @Published var isDeveloperToolVisible = false {
        didSet {
            if isDeveloperToolVisible && isPlaying {
                startWordTracker(for: currentSentence?.text ?? "")
            } else if !isDeveloperToolVisible {
                wordTrackingTask?.cancel()
            }
        }
    }
    @Published var cleanupMode: CleanupMode
    @Published var geminiAPIKey: String

    @Published var cleanupTimeLimit: Int
    @Published private(set) var canReadNow = false
    @Published private(set) var documentWordCount = 0
    @Published var ollamaModel: String
    @Published private(set) var ollamaModels: [String] = []
    @Published private(set) var ollamaStatus = ""
    @Published private(set) var isLoadingOllamaModels = false
    @Published private(set) var importStatus = "Opening document…"

    let kokoroVoices = KokoroVoice.choices
    let systemVoices: [AVSpeechSynthesisVoice]

    private let kokoroEngine: any SpeechEngine
    private let systemEngine: any SpeechEngine
    private var playbackTask: Task<Void, Never>?
    private var wordTrackingTask: Task<Void, Never>?
    private let importPipeline: ImportPipeline
    private let persistState: @Sendable (SavedReaderState, UUID) async -> Void
    private var importTask: Task<Void, Never>?
    private var importID = UUID()
    private var pendingDocument: ReaderDocument?
    private var saveTask: Task<Void, Never>?
    private var documentRevision = UUID()
    private var playbackID = UUID()
    private var didLoadCloudCredential = false
    private var lastSavedCloudCredential = ""
    private let defaults = UserDefaults.standard

    init(kokoroEngine: (any SpeechEngine)? = nil, systemEngine: (any SpeechEngine)? = nil,
         pipeline: ImportPipeline = ImportPipeline(), saved: SavedReaderState? = ReaderStore.load(),
         initialGeminiAPIKey: String? = nil,
         persistState: @escaping @Sendable (SavedReaderState, UUID) async -> Void = ReaderStore.persist) {
        self.kokoroEngine = kokoroEngine ?? KokoroSpeechEngine()
        self.systemEngine = systemEngine ?? SystemSpeechEngine()
        self.importPipeline = pipeline
        self.persistState = persistState
        let initialDocument = saved?.document ?? .welcome
        document = initialDocument
        activeIndex = min(saved?.sentenceIndex ?? 0, max(0, initialDocument.sentences.count - 1))
        speed = saved?.speed ?? 1
        selectedVoiceID = saved?.voiceID ?? "af_heart"
        engineKind = saved?.engineKind ?? .kokoro
        // Old boolean defaults enabled expensive cleanup for every file. Migrate to local-first routing.
        cleanupMode = CleanupMode(rawValue: defaults.string(forKey: "cleanupMode") ?? "") ?? .automatic
        let savedLimit = defaults.integer(forKey: "cleanupTimeLimit")
        cleanupTimeLimit = [15, 30, 60].contains(savedLimit) ? savedLimit : 15
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? ""
        documentWordCount = initialDocument.text.split(whereSeparator: \Character.isWhitespace).count
        geminiAPIKey = initialGeminiAPIKey ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
        systemVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        didLoadCloudCredential = initialGeminiAPIKey != nil || !geminiAPIKey.isEmpty
        lastSavedCloudCredential = geminiAPIKey
    }

    var progress: Double {
        guard !document.sentences.isEmpty else { return 0 }
        return Double(activeIndex + 1) / Double(document.sentences.count)
    }

    var estimatedMinutes: Int {
        return max(1, Int(ceil(Double(documentWordCount) / (175 * speed))))
    }

    var currentSentence: ReaderSentence? {
        document.sentences.indices.contains(activeIndex) ? document.sentences[activeIndex] : nil
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isImporting, !document.sentences.isEmpty else { return }
        if isPaused {
            currentEngine.resume()
            isPaused = false
            isPlaying = true
            activity = .reading
            startWordTracker(for: currentSentence?.text ?? "")
            return
        }

        playbackTask?.cancel()
        let id = UUID()
        playbackID = id
        isPlaying = true
        activity = engineKind == .kokoro ? .preparing : .reading
        playbackTask = Task { [weak self] in
            await self?.playLoop(id: id)
        }
    }

    func pause() {
        // Pause during model preparation must also invalidate the pending synthesis result.
        if activity == .preparing {
            stop()
            activity = .paused
            return
        }
        currentEngine.pause()
        wordTrackingTask?.cancel()
        isPlaying = false
        isPaused = true
        activity = .paused
    }

    func stop() {
        playbackID = UUID()
        currentEngine.stop()
        playbackTask?.cancel()
        wordTrackingTask?.cancel()
        playbackTask = nil
        wordTrackingTask = nil
        isPlaying = false
        isPaused = false
        activeWordIndex = 0
        activity = .ready
    }

    func seek(to index: Int) {
        guard !isImporting else { return }
        let wasPlaying = isPlaying
        stop()
        activeIndex = min(max(0, index), max(0, document.sentences.count - 1))
        save()
        if wasPlaying { play() }
    }

    func skip(by offset: Int) {
        seek(to: activeIndex + offset)
    }

    func changeEngine(to kind: SpeechEngineKind) {
        stop()
        engineKind = kind
        selectedVoiceID = kind == .kokoro
            ? "af_heart"
            : systemVoices.first?.identifier ?? ""
        save()
    }

    func importDocument(from url: URL, autoplay: Bool = false) {
        importSource(from: url, autoplay: autoplay)
    }

    func importSource(from url: URL, autoplay: Bool = false) {
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            reportImportError("Drop a PDF, text file, or article URL.")
            return
        }
        cancelImport()
        stop()
        let id = UUID()
        importID = id
        isImporting = true
        importError = nil
        importStatus = "Opening document…"
        let settings = CleanupSettings(mode: cleanupMode, model: ollamaModel, apiKey: geminiAPIKey,
                                       budget: .seconds(cleanupTimeLimit))
        addDebugLog(.info, "Import started: \(url.lastPathComponent)")
        importTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                var importSettings = settings
                if settings.mode == .gemini && settings.apiKey.isEmpty {
                    await loadCloudCredential()
                    try Task.checkCancellation()
                    importSettings = CleanupSettings(mode: settings.mode, model: settings.model,
                                                     apiKey: geminiAPIKey, budget: settings.budget)
                }
                let basic = try await importPipeline.extract(from: url) { [weak self] level, message in
                    Task { @MainActor in
                        guard let self, self.importID == id else { return }
                        self.addDebugLog(level, message)
                    }
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                pendingDocument = basic
                canReadNow = true
                addDebugLog(.info, "Extracted \(basic.text.count) characters in \(started.duration(to: .now))")
                let outcome = try await importPipeline.cleanup(basic, source: url, settings: importSettings) { [weak self] message in
                    await MainActor.run {
                        guard let self, self.importID == id else { return }
                        self.importStatus = message
                        self.addDebugLog(.info, message)
                    }
                }
                try Task.checkCancellation()
                guard importID == id else { return }
                importError = outcome.notice
                if let notice = outcome.notice { addDebugLog(.warning, notice) }
                commitImport(outcome.document, autoplay: autoplay)
                addDebugLog(.success, "Ready in \(started.duration(to: .now))")
            } catch {
                guard importID == id, !Task.isCancelled else { return }
                isImporting = false
                canReadNow = false
                pendingDocument = nil
                importTask = nil
                reportImportError(error.localizedDescription)
            }
        }
    }

    func cancelImport() {
        importID = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
        canReadNow = false
        pendingDocument = nil
    }

    func readNow() {
        guard let pendingDocument else { return }
        cancelImport()
        importError = nil
        commitImport(pendingDocument, autoplay: true)
        addDebugLog(.info, "AI skipped; reading with fast cleanup")
    }

    private func commitImport(_ imported: ReaderDocument, autoplay: Bool) {
        document = imported
        documentRevision = UUID()
        documentWordCount = imported.text.split(whereSeparator: \Character.isWhitespace).count
        activeIndex = 0
        activeWordIndex = 0
        pendingDocument = nil
        canReadNow = false
        isImporting = false
        importTask = nil
        save()
        if autoplay { play() }
    }

    func dismissImportError() {
        importError = nil
    }

    func reportImportError(_ message: String) {
        importError = message
        addDebugLog(.error, message)
    }

    func save() {
        let snapshot = SavedReaderState(document: document, sentenceIndex: activeIndex,
                                        speed: speed, voiceID: selectedVoiceID, engineKind: engineKind)
        let revision = documentRevision
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                await persistState(snapshot, revision)
            } catch { }
        }
    }

    func shutdown() async {
        cancelImport()
        stop()
        saveTask?.cancel()
        await persistState(SavedReaderState(document: document, sentenceIndex: activeIndex,
                                            speed: speed, voiceID: selectedVoiceID, engineKind: engineKind),
                           documentRevision)
    }

    func saveImportCleanupSettings() {
        defaults.set(cleanupMode.rawValue, forKey: "cleanupMode")
        defaults.set(cleanupTimeLimit, forKey: "cleanupTimeLimit")
        defaults.set(ollamaModel, forKey: "ollamaModel")
        if geminiAPIKey != lastSavedCloudCredential {
            let key = geminiAPIKey
            lastSavedCloudCredential = key
            Task { await KeychainStore.saveGeminiAPIKey(key) }
        }
    }

    func loadCloudCredential() async {
        guard !didLoadCloudCredential, geminiAPIKey.isEmpty else { return }
        didLoadCloudCredential = true
        let key = await KeychainStore.loadGeminiAPIKey()
        // A user may have typed a key while Keychain was being queried.
        if geminiAPIKey.isEmpty {
            geminiAPIKey = key
            lastSavedCloudCredential = key
        }
    }

    private var currentEngine: SpeechEngine {
        engineKind == .kokoro ? kokoroEngine : systemEngine
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    private func addDebugLog(_ level: DebugLogLevel, _ message: String) {
        debugLog.append(DebugLogEntry(date: Date(), level: level, message: message))
        if debugLog.count > 160 {
            debugLog.removeFirst(debugLog.count - 160)
        }
    }

    private func startWordTracker(for sentence: String) {
        wordTrackingTask?.cancel()
        guard isDeveloperToolVisible else { return }
        let words = sentence.split(whereSeparator: \Character.isWhitespace)
        guard !words.isEmpty else {
            activeWordIndex = 0
            return
        }

        activeWordIndex = 0
        let wordsPerMinute = max(90, 175 * speed)
        let millisecondsPerWord = max(160, Int((60 / wordsPerMinute) * 1000))
        wordTrackingTask = Task { [weak self] in
            for index in words.indices {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.activeWordIndex = words.distance(from: words.startIndex, to: index)
                }
                try? await Task.sleep(for: .milliseconds(millisecondsPerWord))
            }
        }
    }

    func refreshOllamaModels() async {
        guard !isLoadingOllamaModels else { return }
        isLoadingOllamaModels = true
        defer { isLoadingOllamaModels = false }
        do {
            ollamaModels = try await OllamaCleanupClient.models()
            ollamaStatus = ollamaModels.isEmpty ? "No local models found. Install a text model in Ollama." : "Ollama connected"
            saveImportCleanupSettings()
        } catch {
            ollamaStatus = "Cannot connect to Ollama. Start Ollama and refresh models."
        }
    }

    private func playLoop(id: UUID) async {
        while playbackID == id && isPlaying && document.sentences.indices.contains(activeIndex) && !Task.isCancelled {
            let sentence = document.sentences[activeIndex]
            activity = engineKind == .kokoro ? .preparing : .reading
            do {
                try await currentEngine.prepare([sentence.text], voice: selectedVoiceID, speed: speed)
                try Task.checkCancellation()
                guard playbackID == id, isPlaying else { return }
                activity = .reading
                startWordTracker(for: sentence.text)
                try await currentEngine.speak(sentence.text, voice: selectedVoiceID, speed: speed)
                guard playbackID == id, !Task.isCancelled else { return }
                wordTrackingTask?.cancel()
                if activeIndex == document.sentences.count - 1 {
                    activeIndex = 0
                    activeWordIndex = 0
                    isPlaying = false
                    activity = .ready
                    save()
                    return
                }
                activeIndex += 1
                activeWordIndex = 0
                save()
                if isPaused {
                    // Completion raced a pause: resume from the next sentence with a new task.
                    isPaused = false
                    activity = .paused
                    return
                }
                activity = .reading
            } catch is CancellationError {
                guard playbackID == id else { return }
                wordTrackingTask?.cancel()
                return
            } catch SpeechEngineError.interrupted {
                guard playbackID == id else { return }
                wordTrackingTask?.cancel()
                return
            } catch {
                guard playbackID == id, !Task.isCancelled else { return }
                wordTrackingTask?.cancel()
                if engineKind == .kokoro {
                    kokoroEngine.stop()
                    engineKind = .system
                    selectedVoiceID = systemVoices.first?.identifier ?? ""
                    activity = .reading
                    continue
                }
                isPlaying = false
                activity = .failed(error.localizedDescription)
                return
            }
        }
    }
}
