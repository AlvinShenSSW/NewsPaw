import NewsPawKit
import SwiftUI

/// Today (ux S1; RD23 decision 12): the date, the status line once the
/// library has a feed-like source (RD06), then, in the owner's order, a
/// card or a compact nothing-new row for each category with overviews on,
/// in an adaptive grid — two columns on an iPad when there is room — and
/// each category with overviews off as its own rounded row. With no
/// category: "Nothing new today". Pull to refresh refreshes the whole
/// library.
struct TodayView: View {
    @Environment(SourceModel.self) private var sources
    @Environment(CategoryModel.self) private var categories
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        let shown = categories.listedSummaries.map(\.category)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodayDateLine()
                if sources.hasFeedLikeSource {
                    TodayStatusLine()
                }
                if shown.isEmpty {
                    EmptyStateView(title: Text("Nothing new today"), systemImage: "sun.max", identifier: AccessibilityID.todayEmpty)
                } else {
                    TodayOverviews(categories: shown)
                        .padding(.top, Theme.Spacing.medium)
                        .padding(.bottom, Theme.Spacing.large)
                }
            }
            // The empty state fills what the bars leave, as it did before
            // Today could scroll. With cards the content keeps its own
            // height, so cards below the fold can be scrolled to.
            .modifier(FillsViewport(when: shown.isEmpty))
        }
        .refreshable {
            await refresh.refresh(.library)
        }
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Today")
    }
}

/// The cards and rows of the categories with overviews on, in an adaptive
/// grid of at least 340 points a column (assumption A4), then the rows of
/// those with overviews off.
private struct TodayOverviews: View {
    let categories: [LibraryCategory]
    @Environment(SourceModel.self) private var sources

    /// The narrowest a column of cards may be.
    static let columnWidth = 340.0

    var body: some View {
        let on = categories.filter { $0.overview != .off }
        let off = categories.filter { $0.overview == .off }
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            if !on.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: Self.columnWidth), spacing: Theme.Spacing.medium, alignment: .top)],
                    alignment: .leading, spacing: Theme.Spacing.medium
                ) {
                    ForEach(on, id: \.id) { category in
                        OverviewTodayItem(category: category, unread: sources.unreadCount(in: category.id))
                    }
                }
            }
            ForEach(off, id: \.id) { category in
                OverviewTodayItem(category: category, unread: sources.unreadCount(in: category.id))
            }
        }
        .padding(.horizontal, Theme.Spacing.standard)
    }
}

/// Makes the scroll content exactly the viewport's height when `when` is
/// true; leaves it its own height otherwise.
private struct FillsViewport: ViewModifier {
    let when: Bool

    func body(content: Content) -> some View {
        if when {
            content.containerRelativeFrame(.vertical, alignment: .top) { length, _ in length }
        } else {
            content
        }
    }
}

/// The date under Today's title, by the library's clock, redrawn every
/// minute so that it turns at midnight.
struct TodayDateLine: View {
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(refresh.now(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.todayDate)
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.bottom, Theme.Spacing.tight)
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
