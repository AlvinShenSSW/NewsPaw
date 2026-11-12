import SwiftUI

/// Today: the overview cards arrive with articles; until then it says so.
struct TodayView: View {
    var body: some View {
        EmptyStateView(title: Text("Nothing new today"), systemImage: "sun.max", identifier: AccessibilityID.todayEmpty)
            .stackBackground(Theme.groupedBackground)
            .navigationTitle("Today")
    }
}
