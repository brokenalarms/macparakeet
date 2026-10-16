import Foundation
import MacParakeetCore

@MainActor
@Observable
final class HistoryViewModel {
    private(set) var dictations: [Dictation] = []
    private(set) var errorMessage: String?
    var searchText = "" {
        didSet { load() }
    }

    @ObservationIgnored private let repo: DictationRepositoryProtocol

    init(repo: DictationRepositoryProtocol) {
        self.repo = repo
    }

    func load() {
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            dictations = query.isEmpty ? try repo.fetchAll(limit: nil) : try repo.search(query: query, limit: nil)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ dictation: Dictation) {
        do {
            _ = try repo.delete(id: dictation.id)
            dictations.removeAll { $0.id == dictation.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func displayText(_ dictation: Dictation) -> String {
        dictation.cleanTranscript ?? dictation.rawTranscript
    }
}
