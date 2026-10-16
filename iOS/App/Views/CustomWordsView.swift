import MacParakeetCore
import SwiftUI

struct CustomWordsView: View {
    let repo: CustomWordRepository
    @State private var viewModel = CustomWordsViewModel()
    @State private var editing: CustomWord?

    var body: some View {
        List {
            Section {
                TextField("Word or phrase", text: $viewModel.newWord)
                    .autocorrectionDisabled()
                TextField("Replacement (optional)", text: $viewModel.newReplacement)
                    .autocorrectionDisabled()
                Button("Add") { viewModel.addWord() }
                    .disabled(viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(viewModel.filteredWords) { word in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(word.word)
                            if let replacement = word.replacement {
                                Text("→ \(replacement)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { word.isEnabled },
                            set: { _ in viewModel.toggleEnabled(word) }
                        ))
                        .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = word }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            viewModel.deleteWord(word)
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText)
        .navigationTitle("Custom Words")
        .onAppear { viewModel.configure(repo: repo) }
        .sheet(item: $editing) { word in
            EditPairSheet(
                title: "Edit Word",
                firstLabel: "Word or phrase",
                secondLabel: "Replacement (optional)",
                first: word.word,
                second: word.replacement ?? ""
            ) { newWord, newReplacement in
                let error = VocabularyEdits.update(word, word: newWord, replacement: newReplacement, in: viewModel.words, repo: repo)
                if error == nil { viewModel.loadWords() }
                return error
            }
        }
    }
}

/// Edits an existing entry with the same trimming and case-insensitive duplicate rules
/// the shared ViewModels apply when adding (they have no edit operation of their own).
enum VocabularyEdits {
    static func update(_ original: CustomWord, word: String, replacement: String, in existing: [CustomWord], repo: CustomWordRepositoryProtocol) -> String? {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty else { return "Word can't be empty" }
        if existing.contains(where: { $0.id != original.id && $0.word.caseInsensitiveCompare(trimmedWord) == .orderedSame }) {
            return "'\(trimmedWord)' already exists"
        }
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = original
        updated.word = trimmedWord
        updated.replacement = trimmedReplacement.isEmpty ? nil : trimmedReplacement
        updated.updatedAt = Date()
        do {
            try repo.save(updated)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func update(_ original: TextSnippet, trigger: String, expansion: String, in existing: [TextSnippet], repo: TextSnippetRepositoryProtocol) -> String? {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let processedExpansion = expansion.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\n", with: "\n")
        guard !trimmedTrigger.isEmpty, !processedExpansion.isEmpty else { return "Trigger and expansion are required" }
        if existing.contains(where: { $0.id != original.id && $0.trigger.caseInsensitiveCompare(trimmedTrigger) == .orderedSame }) {
            return "'\(trimmedTrigger)' already exists"
        }
        var updated = original
        updated.trigger = trimmedTrigger
        updated.expansion = processedExpansion
        updated.updatedAt = Date()
        do {
            try repo.save(updated)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct EditPairSheet: View {
    let title: String
    let firstLabel: String
    let secondLabel: String
    @State var first: String
    @State var second: String
    let save: (String, String) -> String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(firstLabel, text: $first).autocorrectionDisabled()
                TextField(secondLabel, text: $second, axis: .vertical).autocorrectionDisabled()
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        error = save(first, second)
                        if error == nil { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
