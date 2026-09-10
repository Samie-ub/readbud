import AppKit
import Combine
import SwiftUI

@MainActor
final class DeveloperToolPanelController {
    private let size = NSSize(width: 390, height: 680)
    private let reader: ReaderModel
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(reader: ReaderModel) {
        self.reader = reader
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
    }

    func start() {
        positionPanel(animated: false)
        updateVisibility(animated: false)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.positionPanel(animated: true) }
            }
            .store(in: &cancellables)

        reader.$isDeveloperToolVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateVisibility(animated: true)
            }
            .store(in: &cancellables)
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func positionPanel(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let height = min(size.height, screen.visibleFrame.height - 48)
        let frame = NSRect(
            x: screen.visibleFrame.maxX - size.width - 14,
            y: screen.visibleFrame.midY - height / 2,
            width: size.width,
            height: height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func updateVisibility(animated: Bool) {
        if reader.isDeveloperToolVisible {
            if panel.contentView == nil {
                panel.contentView = NSHostingView(rootView: DeveloperToolPanelView(reader: reader))
            }
            positionPanel(animated: animated)
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }
}

private struct DeveloperToolPanelView: View {
    @ObservedObject var reader: ReaderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metrics
            logView
            Divider().overlay(Color.white.opacity(0.12))
            contentView
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("ReadBud internals")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                reader.clearDebugLog()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Clear import log")
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            metricPill("\(reader.document.sentences.count)", "sentences")
            metricPill("\(wordCount)", "words")
            metricPill("\(Int(reader.progress * 100))%", "read")
        }
    }

    private func metricPill(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Import trace")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if reader.isImporting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if reader.debugLog.isEmpty {
                            Text("Drop a public article URL to see request, extraction, cleanup, and error details here.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(reader.debugLog) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 170)
                .onChange(of: reader.debugLog.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func logRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(levelColor(entry.level))
                .frame(width: 6, height: 6)
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(entry.level == .error ? .red : .white.opacity(0.88))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Extracted content")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(subtitleLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(reader.document.sentences) { sentence in
                            Text(attributedSentence(sentence))
                                .font(.system(size: sentence.id == reader.activeIndex ? 12 : 11))
                                .lineSpacing(3)
                                .foregroundStyle(.white.opacity(sentence.id == reader.activeIndex ? 0.96 : 0.56))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.white.opacity(sentence.id == reader.activeIndex ? 0.08 : 0.025),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .id(sentence.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: reader.activeIndex) { _, index in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private func attributedSentence(_ sentence: ReaderSentence) -> AttributedString {
        var attributed = AttributedString(sentence.text)
        guard sentence.id == reader.activeIndex else { return attributed }

        attributed.backgroundColor = Color.white.opacity(0.06)
        let ranges = wordRanges(in: sentence.text)
        guard ranges.indices.contains(reader.activeWordIndex) else { return attributed }
        let wordRange = ranges[reader.activeWordIndex]
        guard let lower = AttributedString.Index(wordRange.lowerBound, within: attributed),
              let upper = AttributedString.Index(wordRange.upperBound, within: attributed) else {
            return attributed
        }

        attributed[lower..<upper].foregroundColor = .black
        attributed[lower..<upper].backgroundColor = .white
        return attributed
    }

    private func wordRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private func levelColor(_ level: DebugLogLevel) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .warning: .yellow
        case .error: .red
        }
    }

    private var statusLine: String {
        if reader.isImporting { return reader.importStatus }
        if let importError = reader.importError { return importError }
        return reader.activity.label
    }

    private var subtitleLine: String {
        "S\(min(reader.activeIndex + 1, reader.document.sentences.count))/\(reader.document.sentences.count) W\(reader.activeWordIndex + 1)"
    }

    private var wordCount: Int {
        reader.documentWordCount
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
