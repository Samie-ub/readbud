import Foundation
import Dispatch
import Darwin

// Wait for filesystem events instead of spawning find/stat/shasum every half second.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceRoot = root.appendingPathComponent("Sources")
let fileManager = FileManager.default

func sourcePaths() -> [URL] {
    var paths = [root, sourceRoot, root.appendingPathComponent("Package.swift"), root.appendingPathComponent("Package.resolved")]
    if let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        for case let url as URL in enumerator { paths.append(url) }
    }
    return paths
}

func fingerprint() -> [String: String] {
    var result: [String: String] = [:]
    for url in sourcePaths() where url != root {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[url.path] = "\(modified)|\(attributes[.size] ?? "")"
        }
    }
    return result
}

let initial = fingerprint()
var sources: [DispatchSourceFileSystemObject] = []
for url in sourcePaths() {
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { continue }
    if ProcessInfo.processInfo.environment["READBUD_WATCH_TRACE"] == "1" { fputs("Watching \(url.path)\n", stderr) }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
        eventMask: [.write, .rename, .delete, .attrib], queue: .main)
    source.setEventHandler {
        if ProcessInfo.processInfo.environment["READBUD_WATCH_TRACE"] == "1" { fputs("Source event\n", stderr) }
        if fingerprint() != initial { exit(0) }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    sources.append(source)
}
// Handle an edit between the initial snapshot and installing event sources.
if fingerprint() != initial { exit(0) }
dispatchMain()
