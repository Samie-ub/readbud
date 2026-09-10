import Foundation
import Testing
@testable import ReadBudMac

struct LiveCleanupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["READBUD_LIVE_OLLAMA"] == "1"))
    func localOllamaSmokeTest() async throws {
        let models = try await OllamaCleanupClient.models()
        #expect(!models.isEmpty)
        let input = "Chapter One\n\nThe launch is on October 4. The price is $12.50.\n\nThe value is -42. Costs rose 5%."
        let start = ContinuousClock.now
        let result = try await withDeadline(.seconds(15)) {
            try await OllamaCleanupClient.clean(input, model: "llama3.2:latest")
        }
        print("ReadBud live Ollama: \(start.duration(to: .now)); \(input.count) → \(result.count) characters")
        #expect(result.contains("12.50"))
        #expect(result.contains("-42"))
    }
}
