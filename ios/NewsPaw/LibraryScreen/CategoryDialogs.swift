import NewsPawKit
import SwiftUI

extension View {
    /// Attaches the category deletion dialog, the save-error alert, and a
    /// move's confirmation and messages (RD19 decision 11). They present
    /// only from the frontmost host, so a dialog shown over a sheet is
    /// attached to the sheet's content and never closes it.
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
            .alert(
                moveTitle(categories.pendingMove),
                isPresented: movePresented,
                presenting: categories.pendingMove
            ) { plan in
                Button("Move", role: .destructive) {
                    categories.confirmMove(plan)
                }
                .accessibilityIdentifier(AccessibilityID.confirmMoveButton)
                Button("Cancel", role: .cancel) {
                    categories.cancelMove()
                }
            } message: { plan in
                Text(verbatim: Self.moveMessage(plan))
            }
            .alert(
                categories.moveMessage.map(Self.messageTitle) ?? Text(verbatim: ""),
                isPresented: messagePresented,
                presenting: categories.moveMessage
            ) { _ in
                Button("OK") {}
            }
    }

    private var movePresented: Binding<Bool> {
        Binding {
            isFrontmost && categories.pendingMove != nil
        } set: { presented in
            if !presented {
                categories.cancelMove()
            }
        }
    }

    private var messagePresented: Binding<Bool> {
        Binding {
            isFrontmost && categories.moveMessage != nil
        } set: { presented in
            if !presented {
                categories.moveMessage = nil
            }
        }
    }

    private func moveTitle(_ plan: CategoryMove.Plan?) -> Text {
        let name = plan?.category.name ?? ""
        return plan?.to == .normal ? Text("Move “\(name)” to the normal partition?") : Text("Move “\(name)” to the adult partition?")
    }

    /// The consequences (N02), and the sources that stay, by name, the
    /// first ten.
    static func moveMessage(_ plan: CategoryMove.Plan) -> String {
        var text = String(
            localized: "Its sources move there and are collected again; new articles there are translated by that partition's model. Here, its \(plan.articleCount) articles are deleted with their translations and overviews, and read and starred states are lost."
        )
        guard !plan.staying.isEmpty else { return text }
        let names = plan.staying.map(\.name)
        let listed = if names.count > 10 {
            names.prefix(10).joined(separator: ", ") + " " + String(localized: "and \(names.count - 10) more")
        } else {
            names.formatted(.list(type: .and))
        }
        let name = plan.category.name
        let staying = plan.to == .normal
            ? String(localized: "Already in the normal partition, so they stay here in “\(name)”: \(listed)")
            : String(localized: "Already in the adult partition, so they stay here in “\(name)”: \(listed)")
        text += "\n\n" + staying
        return text
    }

    static func messageTitle(_ message: MoveMessage) -> Text {
        switch message {
        case .nothingToMove(let name, .normal):
            Text("Every source of “\(name)” is already in the normal partition. Nothing was moved.")
        case .nothingToMove(let name, .adult):
            Text("Every source of “\(name)” is already in the adult partition. Nothing was moved.")
        case .notMoved:
            Text("The category could not be moved. Nothing was changed.")
        case .copiedNotRemoved(let name, .normal):
            Text("“\(name)” was copied to the normal partition but could not be removed here. Move it again to finish.")
        case .copiedNotRemoved(let name, .adult):
            Text("“\(name)” was copied to the adult partition but could not be removed here. Move it again to finish.")
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
