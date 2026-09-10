import Foundation
import PDFKit
import UniformTypeIdentifiers

enum DocumentImportError: LocalizedError {
    case unsupported
    case empty
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported: "Choose a PDF, TXT, or Markdown file."
        case .empty: "No readable text was found in this document."
        case .unreadable: "ReadBud could not open this document."
        }
    }
}

enum DocumentImporter {
    static let allowedTypes: [UTType] = [
        .pdf,
        .plainText,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText
    ]

    static func supports(_ url: URL) -> Bool {
        ["pdf", "txt", "md", "markdown"].contains(url.pathExtension.lowercased())
    }

    static func load(from url: URL) async throws -> ImportedText {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        let contentType = values.contentType
        let text: String

        if contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw DocumentImportError.unreadable }
            text = try (0..<pdf.pageCount)
                .map { index in
                    try Task.checkCancellation()
                    return pdf.page(at: index)?.string ?? ""
                }
                .joined(separator: "\n\n")
        } else if contentType?.conforms(to: .text) == true || ["txt", "md", "markdown"].contains(url.pathExtension.lowercased()) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            throw DocumentImportError.unsupported
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DocumentImportError.empty
        }
        return ImportedText(title: url.deletingPathExtension().lastPathComponent, text: text)
    }
}
