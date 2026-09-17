import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var reader: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: reader.progress)
                .progressViewStyle(.linear)
                .tint(.orange)

            HStack(spacing: 12) {
                Button { reader.skip(by: -1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: .command)

                Button { reader.togglePlayback() } label: {
                    Image(systemName: reader.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.accentColor.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Button { reader.skip(by: 1) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.rightArrow, modifiers: .command)

                VStack(alignment: .leading, spacing: 4) {
                    Text(reader.activity.label)
                        .font(.caption.weight(.semibold))
                    Text(reader.currentSentence?.text ?? "Open a document to begin")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 280, alignment: .leading)
                .padding(.leading, 8)

                Spacer(minLength: 12)

                Picker("Speed", selection: $reader.speed) {
                    ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                        Text("\(speed.formatted())×").tag(speed)
                    }
                }
                .labelsHidden()
                .frame(width: 82)
                .onChange(of: reader.speed) { _, _ in
                    reader.stop()
                    reader.save()
                }

                voicePicker
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
        }
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var voicePicker: some View {
        Picker("Voice", selection: $reader.selectedVoiceID) {
            ForEach(reader.systemVoices, id: \.identifier) { voice in
                Text(voice.name).tag(voice.identifier)
            }
        }
        .labelsHidden()
        .frame(width: 155)
        .onChange(of: reader.selectedVoiceID) { _, _ in
            reader.stop()
            reader.save()
        }
    }
}
