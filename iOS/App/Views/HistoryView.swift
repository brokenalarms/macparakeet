import MacParakeetCore
import SwiftUI
import UIKit

struct HistoryView: View {
    @State var viewModel: HistoryViewModel

    var body: some View {
        NavigationStack {
            List {
                if let error = viewModel.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(viewModel.dictations) { dictation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HistoryViewModel.displayText(dictation))
                            .lineLimit(4)
                        Text(dictation.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            viewModel.delete(dictation)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = HistoryViewModel.displayText(dictation)
                        }
                        .tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = HistoryViewModel.displayText(dictation)
                        }
                    }
                }
            }
            .overlay {
                if viewModel.dictations.isEmpty && viewModel.errorMessage == nil {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No dictations yet" : "No matches",
                        systemImage: "clock"
                    )
                }
            }
            .searchable(text: $viewModel.searchText)
            .navigationTitle("History")
            .onAppear { viewModel.load() }
        }
    }
}
