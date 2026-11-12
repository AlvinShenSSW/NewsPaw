import NewsPawKit
import SwiftUI

/// The sidebar below 1100 pt: presented in a full-screen cover with a clear
/// background, so the system makes it modal (the keyboard is dismissed and
/// nothing behind it can be reached), with a dimmed layer and a panel that
/// slides in from the leading edge.
struct SlideOverSidebar: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(CategoryModel.self) private var categories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.scrim
                .opacity(isShown ? 1 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close(animated: true) }
                .accessibilityHidden(true)
            NavigationStack {
                SidebarView(form: .slideOver(close: close(animated:)))
            }
            .frame(width: WindowLayout.slideOverWidth)
            .paneIdentifier(AccessibilityID.slideOverPanel)
            .accessibilityAction(.escape) { close(animated: true) }
            .offset(x: isShown ? 0 : -WindowLayout.slideOverWidth)
        }
        .presentationBackground(.clear)
        .categoryDialogs(host: .slideOver)
        .sourceDialogs(host: .slideOver)
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
        .onAppear {
            if reduceMotion {
                isShown = true
            } else {
                withAnimation(.easeOut(duration: 0.25)) { isShown = true }
            }
        }
    }

    /// Closes the slide-over, sliding the panel out first unless `animated`
    /// is false or Reduce Motion is on.
    private func close(animated: Bool) {
        guard animated, !reduceMotion, isShown else {
            navigation.closeSlideOver()
            return
        }
        withAnimation(.easeIn(duration: 0.2)) {
            isShown = false
        } completion: {
            navigation.closeSlideOver()
        }
    }
}
