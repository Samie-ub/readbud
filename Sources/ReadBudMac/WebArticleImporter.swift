import Foundation
import WebKit

enum WebArticleImportError: LocalizedError {
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable: "ReadBud could not load that article."
        case .empty: "No readable article text was found."
        }
    }
}

enum WebArticleImporter {
    typealias TraceHandler = @Sendable (DebugLogLevel, String) -> Void

    static func load(from url: URL, onTrace: TraceHandler? = nil) async throws -> ImportedText {
        do {
            return try await loadDirectly(from: url, onTrace: onTrace)
        } catch {
            try Task.checkCancellation()
            onTrace?(.warning, "Direct extraction unavailable: \(error.localizedDescription)")
            onTrace?(.info, "Trying browser rendering for this page")
            return try await RenderedWebArticleImporter.load(from: url, onTrace: onTrace)
        }
    }

    private static func loadDirectly(from url: URL, onTrace: TraceHandler?) async throws -> ImportedText {
        onTrace?(.info, "Requesting article HTML")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15 ReadBud/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<400).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                onTrace?(.error, "HTTP \(httpResponse.statusCode) while fetching article")
            } else {
                onTrace?(.error, "No HTTP response while fetching article")
            }
            throw WebArticleImportError.unreadable
        }
        onTrace?(.success, "HTTP \(httpResponse.statusCode), \(data.count) bytes received")

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            onTrace?(.error, "Could not decode response body as UTF-8 or ISO Latin-1")
            throw WebArticleImportError.unreadable
        }
        onTrace?(.success, "Decoded HTML: \(html.count) characters")

        let title = extractTitle(from: html) ?? readableTitle(from: url)
        onTrace?(.info, "Title resolved: \(title)")

        let candidate: String?
        if let articleText = extractArticleText(from: html, onTrace: onTrace) {
            candidate = articleText
        } else {
            // Client-rendered pages need Readability, not a navigation/body dump.
            throw WebArticleImportError.empty
        }

        let text = sanitizeImportedText(candidate, onTrace: onTrace)

        guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 120 else {
            onTrace?(.error, "Sanitizer returned no readable article text")
            throw WebArticleImportError.empty
        }

        return ImportedText(title: title, text: text)
    }

    private static func extractTitle(from html: String) -> String? {
        if let meta = firstMatch(
            pattern: #"<meta[^>]+property=["']og:title["'][^>]*content=["']([^"']+)["'][^>]*>"#,
            in: html
        ) {
            return decodeHTML(meta)
        }

        guard let title = firstMatch(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, in: html) else {
            return nil
        }
        return decodeHTML(title)
    }

    private static func extractArticleText(from html: String, onTrace: TraceHandler?) -> String? {
        for candidate in [
            ("article", #"<article\b[^>]*>([\s\S]*?)</article>"#),
            ("main", #"<main\b[^>]*>([\s\S]*?)</main>"#),
            ("role=main", #"<div\b[^>]*role=["']main["'][^>]*>([\s\S]*?)</div>"#)
        ] {
            let (name, pattern) = candidate
            if let htmlFragment = firstMatch(pattern: pattern, in: html),
               let text = htmlFragmentToText(htmlFragment) {
                onTrace?(.success, "Matched <\(name)> candidate: \(text.count) text characters")
                return text
            }
        }
        return nil
    }

    private static func htmlFragmentToText(_ fragment: String) -> String? {
        let normalized = fragment
            .replacingOccurrences(of: #"<(script|style|noscript|svg)[^>]*>[\s\S]*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"</(p|div|li|h1|h2|h3|h4|h5|h6|blockquote|pre|tr)>"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"&nbsp;"#, with: " ")
            .replacingOccurrences(of: #"&amp;"#, with: "&")
            .replacingOccurrences(of: #"&quot;"#, with: "\"")
            .replacingOccurrences(of: #"&#39;"#, with: "'")
            .replacingOccurrences(of: #"&lt;"#, with: "<")
            .replacingOccurrences(of: #"&gt;"#, with: ">")

        guard let decoded = decodeHTML(normalized) else {
            return nil
        }

        let lines = decoded
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n\n")
    }

    private static func sanitizeImportedText(_ text: String?, onTrace: TraceHandler?) -> String? {
        guard let text else { return nil }

        let normalized = text
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)

        let rawParagraphs = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let paragraphs = rawParagraphs
            .filter { !isBoilerplateLine($0) }

        onTrace?(.info, "Paragraph cleanup: \(rawParagraphs.count) raw, \(paragraphs.count) after boilerplate filter")
        guard !paragraphs.isEmpty else { return nil }

        let deduped = deduplicate(paragraphs)
        let cleaned = deduped
            .filter { isLikelyArticleLine($0) }
            .joined(separator: "\n\n")

        onTrace?(.info, "Article line filter: \(deduped.count) deduped, \(cleaned.count) final characters")
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isBoilerplateLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let exactMatches: Set<String> = [
            "home",
            "sign in",
            "log in",
            "subscribe",
            "newsletter",
            "share",
            "comments",
            "related",
            "related articles",
            "recommended",
            "advertisement",
            "advertisements",
            "cookie policy",
            "privacy policy",
            "terms of service",
            "all rights reserved"
        ]

        if exactMatches.contains(lowered) { return true }

        let containsMatches = [
            "cookie",
            "privacy",
            "subscribe",
            "newsletter",
            "sign up",
            "log in",
            "follow us",
            "read more",
            "share this",
            "advertisement",
            "related posts",
            "recommended for you",
            "accept cookies"
        ]

        if line.count < 100 && containsMatches.contains(where: { lowered.hasPrefix($0) }) { return true }

        return false
    }

    private static func isLikelyArticleLine(_ line: String) -> Bool {
        line.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func deduplicate(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previous: String?

        for line in lines {
            if line != previous {
                result.append(line)
                previous = line
            }
        }
        return result
    }

    private static func decodeHTML(_ string: String) -> String? {
        // Entity decoding must not instantiate WebKit/NSAttributedString HTML importers.
        var result = string
        let entities = ["&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                        "&ndash;": "–", "&mdash;": "—", "&lsquo;": "‘", "&rsquo;": "’",
                        "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…", "&copy;": "©"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result),
                      let numberRange = Range(match.range(at: 1), in: result) else { continue }
                let number = String(result[numberRange])
                let code = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let code, let scalar = UnicodeScalar(code) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func readableTitle(from url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return url.deletingPathExtension().lastPathComponent.isEmpty ? "Web Article" : url.deletingPathExtension().lastPathComponent
    }
}

private enum RenderedWebArticleImportError: LocalizedError {
    case missingResource
    case navigation(String)
    case invalidResult
    case empty
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingResource:
            "Mozilla Readability is missing from the app bundle."
        case .navigation(let message):
            "The page could not finish loading: \(message)"
        case .invalidResult:
            "The rendered page returned an invalid article."
        case .empty:
            "Mozilla Readability found no article text."
        case .timedOut:
            "The rendered page took too long to load."
        }
    }
}

@MainActor
private final class RenderedWebArticleImporter: NSObject, WKNavigationDelegate {
    private let url: URL
    private let onTrace: WebArticleImporter.TraceHandler?
    private let webView: WKWebView
    private var continuation: CheckedContinuation<ImportedText, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasFinished = false
    private var extractionTask: Task<Void, Never>?

    private init(url: URL, onTrace: WebArticleImporter.TraceHandler?) {
        self.url = url
        self.onTrace = onTrace

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "ReadBud/0.1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func load(from url: URL, onTrace: WebArticleImporter.TraceHandler?) async throws -> ImportedText {
        let importer = RenderedWebArticleImporter(url: url, onTrace: onTrace)
        return try await importer.start()
    }

    private func start() async throws -> ImportedText {
        onTrace?(.info, "Loading page in the browser renderer")

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(Locale.preferredLanguages.prefix(3).joined(separator: ","), forHTTPHeaderField: "Accept-Language")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { return }
                    self?.finish(with: .failure(RenderedWebArticleImportError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(with: .failure(CancellationError()))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onTrace?(.success, "Rendered page loaded: \(webView.url?.absoluteString ?? url.absoluteString)")
        extractionTask?.cancel()
        extractionTask = Task { [weak self] in
            // Some client-rendered sites populate the article immediately after the load event.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.extractArticle()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(RenderedWebArticleImportError.navigation(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: .failure(RenderedWebArticleImportError.navigation(error.localizedDescription)))
    }

    private func extractArticle() async {
        guard !hasFinished, !Task.isCancelled else { return }
        guard let scriptURL = Bundle.module.url(
            forResource: "Readability",
            withExtension: "js",
            subdirectory: "Resources"
        ), let readabilitySource = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            finish(with: .failure(RenderedWebArticleImportError.missingResource))
            return
        }

        let extractionScript = readabilitySource + #"""

        (() => {
            const article = new Readability(document.cloneNode(true)).parse();
            if (!article) return null;
            return {
                title: article.title || document.title || "Web Article",
                text: article.textContent || "",
                byline: article.byline || "",
                siteName: article.siteName || ""
            };
        })();
        """#

        do {
            let result = try await webView.evaluateJavaScript(extractionScript)
            guard let article = result as? [String: Any],
                  let text = article["text"] as? String else {
                finish(with: .failure(RenderedWebArticleImportError.invalidResult))
                return
            }

            let cleanedText = text
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            guard cleanedText.count >= 120 else {
                finish(with: .failure(RenderedWebArticleImportError.empty))
                return
            }

            let extractedTitle = (article["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = extractedTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? url.host?.replacingOccurrences(of: "www.", with: "")
                ?? "Web Article"

            onTrace?(.success, "Mozilla Readability extracted \(cleanedText.count) characters")
            finish(with: .success(ImportedText(title: title, text: cleanedText)))
        } catch {
            finish(with: .failure(error))
        }
    }

    private func finish(with result: Result<ImportedText, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        extractionTask?.cancel()
        extractionTask = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        webView.navigationDelegate = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
