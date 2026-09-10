import AppKit
import Combine
import SwiftUI

@MainActor
private final class DropShelfState: ObservableObject {
    @Published var isExpanded = false
    @Published var isDropTargeted = false
    @Published var isHovered = false
}

@MainActor
final class DropShelfController {
    private let collapsedSize = NSSize(width: 170, height: 22)
    private let expandedSize = NSSize(width: 452, height: 212)
    private let reader: ReaderModel
    private let state = DropShelfState()
    private let panel: NSPanel
    private var currentScreen: NSScreen?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var collapseTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(reader: ReaderModel) {
        self.reader = reader
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: collapsedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let shelfView = DropShelfView(
            reader: reader,
            state: state
        )
        let hostingView = DropShelfHostingView(rootView: shelfView)
        panel.contentView = hostingView

        hostingView.onDragActive = { [weak self] active in
            self?.state.isDropTargeted = active
            if active {
                self?.setExpanded(true)
            } else {
                self?.scheduleCollapse()
            }
        }
        hostingView.onHoverActive = { [weak self] active in
            guard let self else { return }
            self.state.isHovered = active
            if active {
                self.setExpanded(true)
            } else {
                self.scheduleCollapse()
            }
        }
        hostingView.onDropFile = { [weak self] url in
            guard let self else { return }
            self.setExpanded(true)
            self.reader.importSource(from: url, autoplay: true)
        }

        configurePanel()
        observeReader()
    }

    func start() {
        currentScreen = NSScreen.main ?? NSScreen.screens.first
        positionPanel(size: collapsedSize, animated: false)
        panel.orderFrontRegardless()
        installEventMonitors()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    private func observeReader() {
        reader.$isImporting
            .receive(on: RunLoop.main)
            .sink { [weak self] isImporting in
                guard let self else { return }
                if isImporting {
                    self.setExpanded(true)
                } else {
                    self.scheduleCollapse()
                }
            }
            .store(in: &cancellables)
    }

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            let location = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }
            let isNearTop = location.y >= screen.frame.maxY - 80
            let isNearCenter = abs(location.x - screen.frame.midX) <= 280
            if isNearTop && isNearCenter {
                currentScreen = screen
                setExpanded(true)
            }
        case .leftMouseUp:
            scheduleCollapse()
        default:
            break
        }
    }

    private func setExpanded(_ expanded: Bool) {
        collapseTask?.cancel()
        guard state.isExpanded != expanded else { return }
        if expanded {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                state.isExpanded = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                state.isExpanded = false
            }
        }
        positionPanel(size: expanded ? expandedSize : collapsedSize, animated: !expanded)
    }

    private func scheduleCollapse(after delay: Duration = .seconds(0.3)) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            guard !self.reader.isImporting,
                  !self.state.isDropTargeted,
                  !self.state.isHovered
            else { return }
            self.setExpanded(false)
        }
    }

    private func positionPanel(size: NSSize, animated: Bool) {
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let top = screen.frame.maxY
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: top - size.height,
            width: size.width,
            height: size.height
        )

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private final class DropShelfHostingView: NSHostingView<DropShelfView> {
    var onDragActive: (@MainActor (Bool) -> Void)?
    var onDropFile: (@MainActor (URL) -> Void)?
    var onHoverActive: (@MainActor (Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private static let urlPasteboardType = NSPasteboard.PasteboardType("public.url")
    private static let plainTextPasteboardType = NSPasteboard.PasteboardType("public.utf8-plain-text")

    required init(rootView: DropShelfView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, Self.urlPasteboardType, Self.plainTextPasteboardType])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let hoverTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        self.hoverTrackingArea = hoverTrackingArea
        addTrackingArea(hoverTrackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverActive?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverActive?(false)
    }

    @available(*, unavailable)
    required init(rootView: DropShelfView, ignoresSafeArea: Bool) {
        fatalError("init(rootView:ignoresSafeArea:) is unavailable")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard supportedURL(from: sender) != nil else { return [] }
        onDragActive?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        supportedURL(from: sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragActive?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = supportedURL(from: sender) else { return false }
        onDragActive?(false)
        onDropFile?(url)
        return true
    }

    private func supportedURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: false]

        if let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] {
            for object in objects {
                let url = object as URL
                if isSupported(url) { return url }
            }
        }

        if let strings = sender.draggingPasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [NSString] {
            for string in strings {
                if let url = URL(string: string as String), isSupported(url) {
                    return url
                }
            }
        }

        if let string = sender.draggingPasteboard.string(forType: Self.urlPasteboardType),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           isSupported(url) {
            return url
        }

        if let string = sender.draggingPasteboard.string(forType: Self.plainTextPasteboardType),
           let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
           isSupported(url) {
            return url
        }

        return nil
    }

    private func isSupported(_ url: URL) -> Bool {
        if url.isFileURL {
            return DocumentImporter.supports(url)
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return true
    }
}

private struct DropShelfView: View {
    @ObservedObject var reader: ReaderModel
    @ObservedObject var state: DropShelfState

    var body: some View {
        ZStack(alignment: .top) {
            shelfShape(cornerRadius: state.isExpanded ? 18 : 8)
                .fill(.black)

            if state.isExpanded {
                expandedShelf
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(.easeIn(duration: 0.1))
                    ))
            } else {
                collapsedShelf
                    .frame(width: 170, height: 22)
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private var collapsedShelf: some View {
        VoiceWaveView(
            isAnimating: reader.isPlaying,
            compact: true
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ReadBud shelf")
        .accessibilityHint("Move the pointer here to show playback controls")
    }

    private var expandedShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(state.isDropTargeted ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.07))
                    if state.isDropTargeted {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.tint)
                    } else {
                        VoiceWaveView(isAnimating: reader.isPlaying)
                    }
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(headerTitle)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .help(statusText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                shelfSettingsMenu
            }
            .frame(height: 36)

            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: geometry.size.width * reader.progress)
                    }
            }
            .frame(height: 4)
            .accessibilityLabel("Reading progress")
            .accessibilityValue("\(Int(reader.progress * 100)) percent")

            HStack(spacing: 20) {
                Spacer(minLength: 0)
                transportButton("backward.end.fill", help: "Previous sentence") {
                    reader.skip(by: -1)
                }
                .disabled(reader.isImporting)
                if reader.isImporting {
                    Button(reader.canReadNow ? "Read now" : "Cancel") {
                        reader.canReadNow ? reader.readNow() : reader.cancelImport()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(reader.canReadNow ? "Skip AI cleanup and start reading" : "Cancel this import")
                } else {
                    transportButton(
                        reader.isPlaying ? "pause.fill" : "play.fill",
                        help: reader.isPlaying ? "Pause" : "Play",
                        isPrimary: true
                    ) {
                        reader.togglePlayback()
                    }
                }
                transportButton("forward.end.fill", help: "Next sentence") {
                    reader.skip(by: 1)
                }
                .disabled(reader.isImporting)
                Spacer(minLength: 0)
            }
            .frame(height: 44)

            HStack(spacing: 8) {
                Menu {
                    Picker("Speech engine", selection: Binding(
                        get: { reader.engineKind },
                        set: { reader.changeEngine(to: $0) }
                    )) {
                        ForEach(SpeechEngineKind.allCases) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    optionLabel(reader.engineKind == .kokoro ? "Kokoro" : "System", icon: "waveform")
                }
                .frame(width: 112)
                .help("Speech engine")
                .accessibilityLabel("Speech engine: \(reader.engineKind.label)")

                Menu {
                    Picker("Reading speed", selection: $reader.speed) {
                        ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                            Text("\(speed.formatted())×").tag(speed)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    optionLabel("\(reader.speed.formatted())×")
                        .monospacedDigit()
                }
                .frame(width: 68)
                .help("Reading speed")
                .accessibilityLabel("Reading speed: \(reader.speed.formatted()) times")
                .onChange(of: reader.speed) { _, _ in
                    reader.stop()
                    reader.save()
                }

                voicePicker
                    .frame(maxWidth: .infinity)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(reader.isImporting)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .background {
            if state.isDropTargeted {
                shelfShape(cornerRadius: 18)
                    .fill(Color.accentColor.opacity(0.08))
            }
        }
        .overlay {
            if state.isDropTargeted {
                shelfShape(cornerRadius: 18)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }

    private func optionLabel(_ title: String, icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var shelfSettingsMenu: some View {
        Menu {
            Toggle(isOn: $reader.isDeveloperToolVisible) {
                Label("Developer tool", systemImage: "wrench.and.screwdriver")
            }
            Picker("Import cleanup", selection: $reader.cleanupMode) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if reader.isImporting {
                Divider()
                if reader.canReadNow { Button("Read now · skip AI") { reader.readNow() } }
                Button("Cancel import") { reader.cancelImport() }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.065), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Shelf settings")
        .onChange(of: reader.cleanupMode) { _, _ in
            reader.saveImportCleanupSettings()
        }

    }

    private func shelfShape(cornerRadius: CGFloat) -> NotchShape {
        NotchShape(radius: cornerRadius)
    }

    private var statusText: String {
        if reader.isImporting { return reader.importStatus }
        if let error = reader.importError { return error }
        return reader.activity.label
    }

    private var headerTitle: String {
        if state.isDropTargeted { return "Drop to start listening" }
        return reader.document.title
    }

    private var statusColor: Color {
        reader.importError == nil ? .secondary : .red
    }

    private func transportButton(
        _ systemName: String,
        help: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 17 : 13, weight: .semibold))
                .offset(x: systemName == "play.fill" ? 1 : 0)
                .frame(width: isPrimary ? 44 : 34, height: isPrimary ? 44 : 34)
                .contentShape(Circle())
        }
        .buttonStyle(ShelfTransportStyle(isPrimary: isPrimary))
        .help(help)
        .accessibilityLabel(help)
    }

    private var selectedVoiceName: String {
        if reader.engineKind == .kokoro {
            return reader.kokoroVoices.first { $0.id == reader.selectedVoiceID }?
                .label.components(separatedBy: " · ").first ?? "Choose voice"
        }
        return reader.systemVoices.first { $0.identifier == reader.selectedVoiceID }?.name ?? "Choose voice"
    }

    private var voicePicker: some View {
        Menu {
            Picker("Voice", selection: $reader.selectedVoiceID) {
                if reader.engineKind == .kokoro {
                    ForEach(reader.kokoroVoices) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                } else {
                    ForEach(reader.systemVoices, id: \.identifier) { voice in
                        Text(voice.name).tag(voice.identifier)
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            optionLabel(selectedVoiceName, icon: "person.wave.2")
        }
        .help("Voice: \(selectedVoiceName)")
        .accessibilityLabel("Voice: \(selectedVoiceName)")
        .onChange(of: reader.selectedVoiceID) { _, _ in
            reader.stop()
            reader.save()
        }
    }

}

/// A menu-bar notch with concave shoulders and rounded lower corners.
private struct NotchShape: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let paddedRect = rect.insetBy(dx: radius, dy: 0)
        let bottomRightCenter = CGPoint(
            x: paddedRect.maxX - radius,
            y: paddedRect.maxY - radius
        )
        let bottomLeftCenter = CGPoint(
            x: paddedRect.minX + radius,
            y: paddedRect.maxY - radius
        )

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addRelativeArc(
            center: CGPoint(x: rect.maxX, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(270),
            delta: .degrees(-90)
        )
        path.addRelativeArc(
            center: bottomRightCenter,
            radius: radius,
            startAngle: .degrees(0),
            delta: .degrees(90)
        )
        path.addRelativeArc(
            center: bottomLeftCenter,
            radius: radius,
            startAngle: .degrees(90),
            delta: .degrees(90)
        )
        path.addRelativeArc(
            center: CGPoint(x: rect.minX, y: rect.minY + radius),
            radius: radius,
            startAngle: .degrees(0),
            delta: .degrees(-90)
        )
        path.closeSubpath()
        return path
    }
}

private struct VoiceWaveView: View {
    let isAnimating: Bool
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isAnimating)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * 7

            HStack(alignment: .center, spacing: compact ? 2 : 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(barColor)
                        .frame(
                            width: compact ? 1.5 : 2.5,
                            height: barHeight(index: index, phase: phase)
                        )
                }
            }
            .frame(height: compact ? 10 : 20)
        }
        .accessibilityLabel(isAnimating ? "Reading aloud" : "Not reading")
    }

    private var barColor: Color {
        if compact {
            return isAnimating ? .white : .white.opacity(0.65)
        }
        return isAnimating ? .accentColor : .secondary.opacity(0.65)
    }

    private func barHeight(index: Int, phase: TimeInterval) -> CGFloat {
        guard isAnimating else { return compact ? 3 : 5 }
        let wave = (sin(phase + Double(index) * 1.15) + 1) / 2
        let minimum: CGFloat = compact ? 3 : 5
        let range: CGFloat = compact ? 7 : 14
        return minimum + CGFloat(wave) * range
    }
}

private struct ShelfTransportStyle: ButtonStyle {
    var isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isPrimary ? Color.black : Color.white.opacity(0.85))
            .background {
                Circle().fill(isPrimary ? Color.white.opacity(configuration.isPressed ? 0.8 : 0.95) : Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
