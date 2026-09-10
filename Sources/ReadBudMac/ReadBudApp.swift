import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let reader = ReaderModel()
    private(set) var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator(reader: reader)
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await reader.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct ReadBudApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("ReadBud", systemImage: "waveform") {
            MenuBarContent(
                openDocument: { appDelegate.coordinator?.chooseDocument() }
            )
            .environmentObject(appDelegate.reader)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.reader)
                .frame(width: 500, height: 680)
        }
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var reader: ReaderModel
    let openDocument: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(reader.document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(reader.activity.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: reader.progress)

            HStack(spacing: 18) {
                Button { reader.skip(by: -1) } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button { reader.togglePlayback() } label: {
                    Image(systemName: reader.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                Button { reader.skip(by: 1) } label: {
                    Image(systemName: "forward.end.fill")
                }
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)

            Divider()

            if reader.isImporting {
                Text(reader.importStatus).font(.caption).foregroundStyle(.secondary)
                if reader.canReadNow {
                    Button("Read now · skip AI") { reader.readNow() }
                }
                Button("Cancel import") { reader.cancelImport() }
            }
            Button("Open Document…", systemImage: "doc.badge.plus", action: openDocument)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            Divider()
            Button("Quit ReadBud", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
