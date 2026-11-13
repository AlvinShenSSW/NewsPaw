import NewsPawKit
import SwiftUI

/// Today until overviews exist (ux S1; RD09 decision 10): the date, the
/// status line once the library has a feed-like source (RD06), then one
/// compact row per category that has unread articles — icon, name, unread
/// count — each showing that category's list, or "Nothing new today". Pull
/// to refresh refreshes the whole library.
struct TodayView: View {
    @Environment(SourceModel.self) private var sources
    @Environment(CategoryModel.self) private var categories
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        let rows = sources.categoriesWithUnread(categories.summaries)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TodayDateLine()
                if sources.hasFeedLikeSource {
                    TodayStatusLine()
                }
                if rows.isEmpty {
                    EmptyStateView(title: Text("Nothing new today"), systemImage: "sun.max", identifier: AccessibilityID.todayEmpty)
                } else {
                    TodayCategoryRows(rows: rows)
                        .padding(.top, Theme.Spacing.medium)
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

/// The categories with unread articles, in the owner's order, in one
/// rounded group. A row selects the category as the sidebar or Library
/// does; on iPhone that moves to the Library tab.
struct TodayCategoryRows: View {
    let rows: [(category: LibraryCategory, unread: Int)]
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.category.id) { index, row in
                if index > 0 {
                    Theme.hairline
                        .frame(height: 1)
                        .padding(.leading, Theme.Spacing.standard + 28 + Theme.Spacing.medium)
                        .accessibilityHidden(true)
                }
                Button {
                    navigation.select(.category(row.category.id))
                } label: {
                    HStack(spacing: Theme.Spacing.medium) {
                        Image(systemName: row.category.icon.rawValue)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(verbatim: row.category.name)
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.unread, format: .number)
                            .foregroundStyle(Theme.secondaryText)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Theme.Spacing.standard)
                    .padding(.vertical, Theme.Spacing.small)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: row.category.name))
                .accessibilityValue(Text("\(row.unread) unread"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(AccessibilityID.todayCategoryRow(row.category.name))
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .padding(.horizontal, Theme.Spacing.standard)
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
