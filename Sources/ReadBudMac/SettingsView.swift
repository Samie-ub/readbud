import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var reader: ReaderModel

    var body: some View {
        Form {
            Picker("Speech engine", selection: Binding(
                get: { reader.engineKind },
                set: { reader.changeEngine(to: $0) }
            )) {
                ForEach(SpeechEngineKind.allCases) { engine in
                    Text(engine.label).tag(engine)
                }
            }

            Slider(value: $reader.speed, in: 0.75...2, step: 0.25) {
                Text("Reading speed")
            } minimumValueLabel: {
                Text("0.75×")
            } maximumValueLabel: {
                Text("2×")
            }

            LabeledContent("Current speed", value: "\(reader.speed.formatted())×")

            Section("Import cleanup") {
                Picker("Cleanup", selection: $reader.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("AI time limit", selection: $reader.cleanupTimeLimit) {
                    ForEach([15, 30, 60], id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(reader.cleanupMode == .basic)
                Text("Automatic makes Markdown and text ready immediately using local formatting cleanup. AI is reserved for short, messy PDF or article extractions. Choose Local AI to request it for every import. If the time limit is reached, the full document uses fast cleanup.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Ollama model", selection: $reader.ollamaModel) {
                    Text("Automatic").tag("")
                    ForEach(reader.ollamaModels, id: \.self) { Text($0).tag($0) }
                    if !reader.ollamaModel.isEmpty && !reader.ollamaModels.contains(reader.ollamaModel) {
                        Text(reader.ollamaModel).tag(reader.ollamaModel)
                    }
                }
                Button(reader.isLoadingOllamaModels ? "Connecting…" : "Refresh models") {
                    Task { await reader.refreshOllamaModels() }
                }
                .disabled(reader.isLoadingOllamaModels)
                Text(reader.ollamaStatus).font(.caption).foregroundStyle(.secondary)
                if reader.cleanupMode == .gemini {
                    SecureField("Gemini API key", text: $reader.geminiAPIKey)
                        .textContentType(.password)
                        .task { await reader.loadCloudCredential() }
                }

                Text("Gemini receives article text only when Cloud AI is explicitly selected. Other modes stay local. Source files are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Kokoro runs locally with Core ML. Its model downloads once on first use; if it is unavailable, ReadBud switches to Apple system speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .task { await reader.refreshOllamaModels() }
        .onChange(of: reader.cleanupMode) { _, _ in reader.saveImportCleanupSettings() }
        .onChange(of: reader.cleanupTimeLimit) { _, _ in reader.saveImportCleanupSettings() }
        .onChange(of: reader.ollamaModel) { _, _ in reader.saveImportCleanupSettings() }
        .onDisappear {
            reader.save()
            reader.saveImportCleanupSettings()
        }
    }
}
