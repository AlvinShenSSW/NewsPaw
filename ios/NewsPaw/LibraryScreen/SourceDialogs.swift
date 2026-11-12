import NewsPawKit
import SwiftUI

extension View {
    /// Attaches the source deletion dialog and the source save-error alert.
    /// Like the category dialogs they present only from the frontmost host,
    /// so a dialog shown over a sheet is attached to the sheet and never
    /// closes it.
    func sourceDialogs(host: CategoryDialogHost) -> some View {
        modifier(SourceDialogs(host: host))
    }
}

private struct SourceDialogs: ViewModifier {
    let host: CategoryDialogHost
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources

    func body(content: Content) -> some View {
        let pending = sources.pendingDeletion
        content
            .confirmationDialog(
                Text("Delete “\(pending?.name ?? "")”?"),
                isPresented: deletionPresented,
                titleVisibility: .visible,
                presenting: pending
            ) { summary in
                Button("Delete Source", role: .destructive) {
                    Task { await sources.delete(summary) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { summary in
                if summary.articleCount > 0 {
                    Text("Its \(summary.articleCount) articles are deleted with it, including any you starred.")
                }
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
            isFrontmost && sources.pendingDeletion != nil
        } set: { presented in
            if !presented {
                sources.pendingDeletion = nil
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding {
            isFrontmost && sources.isShowingSaveError
        } set: { presented in
            if !presented {
                sources.isShowingSaveError = false
            }
        }
    }
}
