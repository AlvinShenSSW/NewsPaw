import SwiftUI

/// Today: the status line once the library has a feed-like source (ux S1;
/// RD06), then — until the overview cards arrive with articles — what the
/// library holds. Pull to refresh refreshes the whole library.
struct TodayView: View {
    @Environment(SourceModel.self) private var sources
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if sources.hasFeedLikeSource {
                    TodayStatusLine()
                }
                Group {
                    if sources.totalUnread > 0 {
                        InterimUnreadView(count: sources.totalUnread)
                    } else {
                        EmptyStateView(title: Text("Nothing new today"), systemImage: "sun.max", identifier: AccessibilityID.todayEmpty)
                    }
                }
            }
            // The empty state fills what the bars leave, as it did before
            // Today could scroll.
            .containerRelativeFrame(.vertical, alignment: .top) { length, _ in length }
        }
        .refreshable {
            await refresh.refresh(.library)
        }
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Today")
    }
}

/// "Updating…", "Updated ⟨time⟩" or "Not updated yet", and beside it "N
/// sources failed" as a button that shows the category list with those
/// sources' categories expanded (RD06 decision 11). The time is relative to
/// the library's clock and redrawn every minute.
struct TodayStatusLine: View {
    @Environment(SourceModel.self) private var sources
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        let failed = sources.failingSources.count
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                status
                if failed > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                    failures(failed)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                status
                if failed > 0 {
                    failures(failed)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.horizontal, Theme.Spacing.standard)
    }

    private var status: some View {
        TimelineView(.everyMinute) { _ in
            statusText
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Theme.minimumTapTarget)
                .accessibilityIdentifier(AccessibilityID.todayStatus)
        }
    }

    private var statusText: Text {
        if !refresh.engine.collecting.isEmpty {
            return Text("Updating…")
        }
        guard let last = refresh.lastRefreshAt else {
            return Text("Not updated yet")
        }
        let now = refresh.now()
        if last <= now, now.timeIntervalSince(last) < 60 {
            return Text("Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return Text("Updated \(formatter.localizedString(for: last, relativeTo: now))")
    }

    private func failures(_ count: Int) -> some View {
        Button {
            sources.showFailingSources()
        } label: {
            Text("\(count) sources failed")
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: Theme.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: Theme.minimumTapTarget)
        .accessibilityIdentifier(AccessibilityID.failedSourcesButton)
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
