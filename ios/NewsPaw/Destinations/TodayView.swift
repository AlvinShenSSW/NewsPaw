import SwiftUI

/// Today: the overview cards arrive with articles; until then it says so,
/// or, once sources hold unread articles, how many there are.
struct TodayView: View {
    @Environment(SourceModel.self) private var sources

    var body: some View {
        Group {
            if sources.totalUnread > 0 {
                InterimUnreadView(count: sources.totalUnread)
            } else {
                EmptyStateView(title: Text("Nothing new today"), systemImage: "sun.max", identifier: AccessibilityID.todayEmpty)
            }
        }
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Today")
    }
}

/// Until article lists exist (RD09), a destination whose scope holds unread
/// articles says how many, in one sentence. RD09 deletes this view.
struct InterimUnreadView: View {
    let count: Int

    var body: some View {
        EmptyStateView(
            title: Text("\(count) unread articles — article lists are not available in this version yet."),
            systemImage: "tray.full", identifier: AccessibilityID.interimUnread
        )
    }
}
