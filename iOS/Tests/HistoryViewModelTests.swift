import MacParakeetCore
import XCTest

@MainActor
final class HistoryViewModelTests: XCTestCase {
    private var repo: DictationRepository!

    override func setUp() async throws {
        repo = DictationRepository(dbQueue: try DatabaseManager().dbQueue)
    }

    func testListsVisibleDictationsNewestFirst() throws {
        try repo.save(Dictation(createdAt: Date(timeIntervalSince1970: 1), durationMs: 1, rawTranscript: "older"))
        try repo.save(Dictation(createdAt: Date(timeIntervalSince1970: 2), durationMs: 1, rawTranscript: "newer"))
        try repo.save(Dictation(createdAt: Date(timeIntervalSince1970: 3), durationMs: 1, rawTranscript: "", hidden: true))
        let viewModel = HistoryViewModel(repo: repo)
        viewModel.load()
        XCTAssertEqual(viewModel.dictations.map(\.rawTranscript), ["newer", "older"])
    }

    func testSearchFiltersBySubstring() throws {
        try repo.save(Dictation(durationMs: 1, rawTranscript: "buy milk"))
        try repo.save(Dictation(durationMs: 1, rawTranscript: "call mom"))
        let viewModel = HistoryViewModel(repo: repo)
        viewModel.searchText = "mil"
        XCTAssertEqual(viewModel.dictations.map(\.rawTranscript), ["buy milk"])
    }

    func testDeleteRemovesDictation() throws {
        let dictation = Dictation(durationMs: 1, rawTranscript: "gone")
        try repo.save(dictation)
        let viewModel = HistoryViewModel(repo: repo)
        viewModel.load()
        viewModel.delete(dictation)
        XCTAssertTrue(viewModel.dictations.isEmpty)
        XCTAssertNil(try repo.fetch(id: dictation.id))
    }

    func testDisplayTextPrefersCleanTranscript() {
        XCTAssertEqual(HistoryViewModel.displayText(Dictation(durationMs: 1, rawTranscript: "um hi", cleanTranscript: "Hi")), "Hi")
        XCTAssertEqual(HistoryViewModel.displayText(Dictation(durationMs: 1, rawTranscript: "raw")), "raw")
    }
}
