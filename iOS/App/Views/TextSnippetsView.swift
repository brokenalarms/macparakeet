import MacParakeetCore
import SwiftUI

struct TextSnippetsView: View {
    let repo: TextSnippetRepository
    @State private var viewModel = TextSnippetsViewModel()
    @State private var editing: TextSnippet?

    var body: some View {
        List {
            Section {
                TextField("Trigger phrase", text: $viewModel.newTrigger)
                    .autocorrectionDisabled()
                TextField("Expansion (\\n for a new line)", text: $viewModel.newExpansion, axis: .vertical)
                    .autocorrectionDisabled()
                Button("Add") { viewModel.addSnippet() }
                    .disabled(viewModel.newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || viewModel.newExpansion.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(viewModel.filteredSnippets) { snippet in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snippet.trigger)
                            Text(snippet.expansion).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { snippet.isEnabled },
                            set: { _ in viewModel.toggleEnabled(snippet) }
                        ))
                        .labelsHidden()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { editing = snippet }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            viewModel.deleteSnippet(snippet)
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText)
        .navigationTitle("Text Snippets")
        .onAppear { viewModel.configure(repo: repo) }
        .sheet(item: $editing) { snippet in
            EditPairSheet(
                title: "Edit Snippet",
                firstLabel: "Trigger phrase",
                secondLabel: "Expansion",
                first: snippet.trigger,
                second: snippet.expansion.replacingOccurrences(of: "\n", with: "\\n")
            ) { trigger, expansion in
                let error = VocabularyEdits.update(snippet, trigger: trigger, expansion: expansion, in: viewModel.snippets, repo: repo)
                if error == nil { viewModel.loadSnippets() }
                return error
            }
        }
    }
}
