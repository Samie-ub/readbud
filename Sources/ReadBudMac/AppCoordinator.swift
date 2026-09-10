import AppKit
import SwiftUI

@MainActor
final class AppCoordinator {
    private let reader: ReaderModel
    private var dropShelf: DropShelfController?
    private var developerToolPanel: DeveloperToolPanelController?

    init(reader: ReaderModel) {
        self.reader = reader
    }

    func start() {
        let shelf = DropShelfController(reader: reader)
        dropShelf = shelf
        shelf.start()

        let developerToolPanel = DeveloperToolPanelController(reader: reader)
        self.developerToolPanel = developerToolPanel
        developerToolPanel.start()
    }

    func chooseDocument() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = DocumentImporter.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        reader.importSource(from: url)
    }
}
