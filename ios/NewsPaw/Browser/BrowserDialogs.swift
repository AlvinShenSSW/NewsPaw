import NewsPawKit
import SwiftUI

extension View {
    /// Attaches the browser's question about another app's link, its file
    /// notice and "No app on this device can open this link." (RD10
    /// decision 5). They are raised only while no sheet is open, so they
    /// present from the root and never close a sheet.
    func browserDialogs() -> some View {
        modifier(BrowserDialogs())
    }
}

private struct BrowserDialogs: ViewModifier {
    @Environment(BrowserModel.self) private var browser
    @Environment(CategoryModel.self) private var categories
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let question = browser.question
        let notice = browser.fileNotice
        content
            .alert(
                Text("Open this link in another app?"),
                isPresented: presented(browser.question != nil) { browser.question = nil },
                presenting: question
            ) { question in
                Button("Open") {
                    browser.open(question)
                }
                Button("Cancel", role: .cancel) {}
            } message: { question in
                Text("This is a “\(question.scheme)” link.")
            }
            .alert(
                Text("This link is a file. NewsPaw does not download files."),
                isPresented: presented(browser.fileNotice != nil) { browser.fileNotice = nil },
                presenting: notice
            ) { notice in
                if let url = notice.url {
                    Button("Open in Safari") {
                        openURL(url)
                    }
                }
                Button("OK", role: .cancel) {}
            }
            .alert(
                Text("No app on this device can open this link."),
                isPresented: presented(browser.isShowingNoApp) { browser.isShowingNoApp = false }
            ) {
                Button("OK", role: .cancel) {}
            }
    }

    private func presented(_ shown: Bool, dismiss: @escaping () -> Void) -> Binding<Bool> {
        Binding {
            shown && categories.activeDialogHost == .root
        } set: { presented in
            if !presented {
                dismiss()
            }
        }
    }
}
