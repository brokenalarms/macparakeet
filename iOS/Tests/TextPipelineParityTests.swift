import MacParakeetCore
import XCTest

/// Same inputs and expectations as the Mac suite's TextRefinementServiceTests: both apps
/// compile the same TextProcessingPipeline source, so clean mode must agree (REQ-IOS-001).
final class TextPipelineParityTests: XCTestCase {
    func testCleanModeRemovesFillers() async {
        let result = await TextRefinementService().refine(rawText: "um hello world", mode: .clean, customWords: [], snippets: [])
        XCTAssertEqual(result.text, "Hello world")
    }

    func testRawModeLeavesTextUntouched() async {
        let result = await TextRefinementService().refine(rawText: "um hello world", mode: .raw, customWords: [], snippets: [])
        XCTAssertNil(result.text)
    }

    func testRawModeStillExtractsVoiceReturn() async {
        let snippets = [TextSnippet(trigger: "return", expansion: "return", action: .returnKey)]
        let result = await TextRefinementService().refine(rawText: "hello return", mode: .raw, customWords: [], snippets: snippets)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.postPasteAction, .returnKey)
    }

    func testRawModeSkipsTextSnippets() async {
        let snippets = [TextSnippet(trigger: "my sig", expansion: "Best regards")]
        let result = await TextRefinementService().refine(rawText: "hello my sig", mode: .raw, customWords: [], snippets: snippets)
        XCTAssertNil(result.text)
    }

    func testProcessingModeDefaultsToRaw() {
        let defaults = UserDefaults(suiteName: "TextPipelineParityTests-\(UUID().uuidString)")!
        XCTAssertEqual(AppSettings.processingMode(defaults), .raw)
        defaults.set("clean", forKey: AppSettings.processingModeKey)
        XCTAssertEqual(AppSettings.processingMode(defaults), .clean)
    }
}
