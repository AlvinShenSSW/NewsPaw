import NewsPawKit
import SwiftUI

extension View {
    /// Attaches the category deletion dialog and the save-error alert. They
    /// present only from the frontmost host, so a dialog shown over a sheet
    /// is attached to the sheet's content and never closes it.
    func categoryDialogs(host: CategoryDialogHost) -> some View {
        modifier(CategoryDialogs(host: host))
    }
}

private struct CategoryDialogs: ViewModifier {
    let host: CategoryDialogHost
    @Environment(CategoryModel.self) private var categories

    func body(content: Content) -> some View {
        let pending = categories.pendingDeletion
        content
            .confirmationDialog(
                deletionTitle(pending),
                isPresented: deletionPresented,
                titleVisibility: .visible,
                presenting: pending
            ) { summary in
                deletionActions(summary)
            } message: { summary in
                deletionMessage(summary)
            }
            .alert("The change could not be saved.", isPresented: errorPresented) {
                Button("OK") {}
            }
    }

    private var isFrontmost: Bool {
        categories.activeDialogHost == host
    }

    private var deletionPresented: Binding<Bool> {
        Binding {
            isFrontmost && categories.pendingDeletion != nil
        } set: { presented in
            if !presented {
                categories.deletionDialogDismissed()
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding {
            isFrontmost && categories.isShowingSaveError
        } set: { presented in
            if !presented {
                categories.isShowingSaveError = false
            }
        }
    }

    private func deletionTitle(_ summary: CategorySummary?) -> Text {
        Text("Delete “\(summary?.category.name ?? "")”?")
    }

    @ViewBuilder
    private func deletionActions(_ summary: CategorySummary) -> some View {
        if summary.sourceCount == 0 {
            Button("Delete Category", role: .destructive) {
                delete(summary, .deleteSources)
            }
        } else {
            ForEach(categories.moveTargets(for: summary)) { target in
                Button("Move Sources to “\(target.category.name)”") {
                    delete(summary, .move(to: target.id))
                }
            }
            Button("Delete Category and Sources", role: .destructive) {
                delete(summary, .deleteSources)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func deletionMessage(_ summary: CategorySummary) -> some View {
        if summary.sourceCount > 0 {
            if categories.moveTargets(for: summary).isEmpty {
                Text("This category has \(summary.sourceCount) sources. There is no other category to move them to, so they are deleted with it.")
            } else {
                Text("This category has \(summary.sourceCount) sources. Move them to another category, or delete them with it.")
            }
        }
    }

    private func delete(_ summary: CategorySummary, _ sources: CategorySourcesDisposition) {
        Task { await categories.delete(summary, sources: sources) }
    }
}
