import NewsPawKit
import SwiftUI

/// Earlier Overviews (ux S3; RD23 decision 12): the category's `done`
/// overviews in the reading language of the days before today in the
/// 7-day window, newest first, each under its date with its summary,
/// highlights, footnote and the not-verification line. A highlight closes
/// the sheet and opens its article.
struct EarlierOverviewsView: View {
    let categoryID: UUID
    @Environment(OverviewModel.self) private var overviews
    @Environment(CategoryModel.self) private var categories
    @Environment(NavigationModel.self) private var navigation
    @Environment(ReadingModel.self) private var reading
    @State private var entries: [StoredOverview]?

    var body: some View {
        let name = categories.summary(categoryID)?.category.name ?? ""
        NavigationStack {
            Group {
                if let entries, entries.isEmpty {
                    EmptyStateView(
                        title: Text("No earlier overviews"), systemImage: "clock", identifier: AccessibilityID.noEarlierOverviews
                    )
                } else {
                    List {
                        ForEach(entries ?? []) { entry in
                            Section {
                                OverviewDoneContent(
                                    overview: entry, name: "\(name).\(entry.day)", place: .earlier, categoryID: categoryID
                                ) { highlight in
                                    navigation.sheet = nil
                                    reading.open(articleID: highlight.articleID, on: .category(categoryID))
                                }
                                .padding(.vertical, Theme.Spacing.small)
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier(AccessibilityID.earlierOverview(entry.day))
                            } header: {
                                Text(Self.date(of: entry), format: .dateTime.weekday(.wide).month(.wide).day())
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier(AccessibilityID.earlierOverviewsList)
                }
            }
            .background(Theme.groupedBackground)
            .navigationTitle("Earlier Overviews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        navigation.sheet = nil
                    }
                    .accessibilityIdentifier(AccessibilityID.earlierOverviewsDoneButton)
                }
            }
        }
        .task {
            entries = await overviews.earlier(categoryID)
        }
    }

    /// Noon of the day an entry was written for: its key, a Gregorian
    /// date in the device's time zone; its writing time if the key does
    /// not read.
    private static func date(of entry: StoredOverview) -> Date {
        let parts = entry.day.split(separator: "-").compactMap { Int($0) }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .autoupdatingCurrent
        guard parts.count == 3, let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else {
            return entry.createdAt
        }
        return date
    }
}
