import Foundation
import Testing
@testable import ReadBudMac

private final class OllamaStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-ReadBud-Test") ?? ""
        let body: String
        var status = 200
        switch scenario {
        case "models":
            body = #"{"models":[{"name":"llama3.2:latest","capabilities":["completion"]},{"name":"embeddinggemma:latest","capabilities":["embedding"]},{"name":"remote:cloud","remote_host":"https://ollama.com","capabilities":["completion"]}]}"#
        case "empty": body = #"{"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"#
        case "truncated": body = #"{"message":{"role":"assistant","content":"Keep every word in this document."},"done":true,"done_reason":"length"}"#
        case "error": body = #"{"error":"model unavailable"}"#; status = 404
        default: body = "invalid JSON"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct OllamaClientTests {
    private func session(_ scenario: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-ReadBud-Test": scenario]
        return URLSession(configuration: configuration)
    }

    @Test func excludesEmbeddingAndRemoteModels() async throws {
        let session = session("models")
        defer { session.invalidateAndCancel() }
        #expect(try await OllamaCleanupClient.models(session: session) == ["llama3.2:latest"])
    }

    @Test(arguments: ["empty", "truncated", "error", "malformed"])
    func invalidProviderResponsesAreRejected(_ scenario: String) async {
        let session = session(scenario)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await OllamaCleanupClient.clean("Keep every word in this document.", model: "test", session: session)
            Issue.record("Invalid provider response was accepted: \(scenario)")
        } catch { }
    }
}
