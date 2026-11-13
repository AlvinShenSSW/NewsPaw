import NewsPawKit
import SwiftUI

extension View {
    /// Attaches the "Mark All as Read" question (RD09 decision 7). Like the
    /// category and source dialogs it presents only from the frontmost
    /// host, so it never closes a sheet or waits behind the slide-over.
    func markAllReadDialog(host: CategoryDialogHost) -> some View {
        modifier(MarkAllReadDialog(host: host))
    }
}

private struct MarkAllReadDialog: ViewModifier {
    let host: CategoryDialogHost
    @Environment(CategoryModel.self) private var categories
    @Environment(ReadingModel.self) private var reading

    func body(content: Content) -> some View {
        let pending = reading.pendingMarkAll
        content
            .alert(
                Text("Mark \(pending?.count ?? 0) articles as read?"),
                isPresented: presented,
                presenting: pending
            ) { request in
                Button("Mark as Read") {
                    reading.confirmMarkAllRead(request)
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private var presented: Binding<Bool> {
        Binding {
            categories.activeDialogHost == host && reading.pendingMarkAll != nil
        } set: { presented in
            if !presented {
                reading.pendingMarkAll = nil
            }
        }
    }
}
