import NewsPawKit
import SwiftUI

/// The wording of overviews (ux S1, section 4; RD23 decision 12). Reuses
/// RD14's sentences of the service and the set-up.
enum OverviewWording {
    /// A failure's sentence.
    static func sentence(_ issue: OverviewIssue) -> String {
        switch issue {
        case .stored(.refused): String(localized: "The model declined to write this overview")
        case .stored: String(localized: "The reply could not be used")
        case .blocked(.service(.limited)): String(localized: "The service is limiting requests. Try again later")
        case .blocked(.service): String(localized: "Could not reach the service")
        case .blocked(.setUp(.keyRejected)): String(localized: "The service rejected the key")
        case .blocked(.setUp(.modelNotFound)): String(localized: "The service does not have this model")
        case .blocked(.setUp): String(localized: "Set up a model to get overviews")
        case .blocked(.dailyLimit): String(localized: "Today's automatic limit is reached. Write it manually, or raise the limit in Settings")
        case .blocked(.storage): String(localized: "The change could not be saved.")
        }
    }

    /// The step a failure offers (ux section 4: every failure is followed
    /// by its next step).
    enum Step: Equatable {
        case retry
        case write
        case openSettings
    }

    static func step(_ issue: OverviewIssue) -> Step {
        switch issue {
        case .blocked(.setUp): .openSettings
        case .blocked(.dailyLimit): .write
        case .stored, .blocked(.service), .blocked(.storage): .retry
        }
    }

    static func title(_ step: Step) -> String {
        switch step {
        case .retry: String(localized: "Retry")
        case .write: String(localized: "Write Overview")
        case .openSettings: String(localized: "Open Settings")
        }
    }
}

/// What a step does.
@MainActor
enum OverviewSteps {
    static func take(_ step: OverviewWording.Step, category: UUID, overviews: OverviewModel, navigation: NavigationModel) {
        overviews.question = nil
        switch step {
        case .retry, .write:
            overviews.write(category)
        case .openSettings:
            navigation.openModelSettings()
        }
    }
}

/// The model's text as plain text, never read as Markdown or HTML (RD23
/// decision 12), in the environment of the reading language it was written
/// in.
private func modelText(_ text: String, _ locale: ReadingLocale) -> some View {
    Text(verbatim: text)
        .environment(\.locale, Locale(identifier: locale.rawValue))
}

// MARK: - Today (ux S1)

/// A category's place on Today: its card, or the compact nothing-new or
/// off row (decision 12; the owner's mock-up).
struct OverviewTodayItem: View {
    let category: LibraryCategory
    let unread: Int
    @Environment(OverviewModel.self) private var overviews

    var body: some View {
        switch overviews.state(of: category) {
        case .off:
            OverviewCompactRow(category: category, detail: Text("\(unread) unread · Overviews off"), part: "off", unread: unread)
        case .nothingNew:
            OverviewCompactRow(category: category, detail: Text("Nothing new today"), part: "nothingNew", unread: unread)
        case let state:
            OverviewTodayCard(category: category, unread: unread, state: state)
        }
    }
}

/// A rounded row: icon, name, a line, and a chevron; it opens the
/// category's list.
private struct OverviewCompactRow: View {
    @Environment(\.accent) private var accent
    @Environment(NavigationModel.self) private var navigation
    let category: LibraryCategory
    let detail: Text
    let part: String
    let unread: Int
    /// The icon's column, growing with the text size.
    @ScaledMetric private var iconWidth = 28.0

    var body: some View {
        Button {
            navigation.select(.category(category.id))
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: category.icon.rawValue)
                    .foregroundStyle(accent)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: category.name)
                        .foregroundStyle(Theme.text)
                    detail
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.overview(part, category.name))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("\(unread) unread"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.todayCategoryRow(category.name))
    }
}

/// A category's card on Today: the header, then the state's content.
private struct OverviewTodayCard: View {
    @Environment(\.accent) private var accent
    @Environment(NavigationModel.self) private var navigation
    let category: LibraryCategory
    let unread: Int
    let state: OverviewCardState
    /// The icon's column, growing with the text size.
    @ScaledMetric private var iconWidth = 28.0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            header
            OverviewStateContent(category: category, state: state, place: .today)
        }
        .padding(Theme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.overview("card", category.name))
    }

    /// Icon, name, unread count and chevron: opens the category's list.
    private var header: some View {
        Button {
            navigation.select(.category(category.id))
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: category.icon.rawValue)
                    .foregroundStyle(accent)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                Text(verbatim: category.name)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if unread > 0 {
                    Text(unread, format: .number)
                        .foregroundStyle(Theme.secondaryText)
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: category.name))
        .accessibilityValue(Text("\(unread) unread"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.todayCategoryRow(category.name))
    }
}

// MARK: - The category's list (ux S3)

/// The first row of an `auto` or `manual` category's list: "Today's
/// Overview", collapsed to two lines with Expand, or expanded as on Today
/// with Earlier Overviews (decision 12); the other states as on Today,
/// with Earlier Overviews (`offersEarlier`).
struct OverviewListCard: View {
    let category: LibraryCategory
    @Environment(OverviewModel.self) private var overviews
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let state = overviews.state(of: category)
        let expanded = overviews.expandedListCards.contains(category.id)
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            // The title and Expand side by side, or one above the other
            // when the text is too large for both on one line.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    expandButton(state: state, expanded: expanded)
                }
                VStack(alignment: .leading, spacing: 0) {
                    title
                        .fixedSize(horizontal: false, vertical: true)
                    expandButton(state: state, expanded: expanded)
                }
            }
            if case .done(let overview, let working) = state, !expanded {
                if working {
                    OverviewWorkingLine(name: category.name)
                }
                modelText(overview.text ?? "", overview.locale)
                    .lineLimit(2)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.overview("summary", category.name))
            } else {
                OverviewStateContent(category: category, state: state, place: .list)
            }
            if Self.offersEarlier(state, expanded: expanded) {
                Button {
                    navigation.sheet = .earlierOverviews(category.id)
                } label: {
                    Text("Earlier Overviews")
                        .frame(minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .accessibilityIdentifier(AccessibilityID.overview("earlier", category.name))
            }
        }
        .padding(Theme.Spacing.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.overview("card", category.name))
    }
}

extension OverviewListCard {
    /// Earlier Overviews is the way to the category's history (ux S3), so
    /// every state of the card offers it: a `done` overview once expanded,
    /// as the design draws it, and every other state at once — nothing
    /// new, writing, failed, the limit, write, no model (review round 2).
    /// The sheet says "No earlier overviews" when there are none. Today
    /// does not offer it: its card header and rows open this list.
    static func offersEarlier(_ state: OverviewCardState, expanded: Bool) -> Bool {
        switch state {
        case .done: expanded
        case .off: false
        case .working, .failed, .noModel, .write, .nothingNew: true
        }
    }

    private var title: some View {
        Text("Today's Overview")
            .font(.headline)
            .foregroundStyle(Theme.text)
    }

    @ViewBuilder
    private func expandButton(state: OverviewCardState, expanded: Bool) -> some View {
        if case .done = state {
            Button {
                if expanded {
                    overviews.expandedListCards.remove(category.id)
                } else {
                    overviews.expandedListCards.insert(category.id)
                }
            } label: {
                Text(expanded ? "Less" : "Expand")
                    .frame(minWidth: Theme.minimumTapTarget, minHeight: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .accessibilityIdentifier(AccessibilityID.overview("expand", category.name))
        }
    }
}

// MARK: - The content of a state

/// Where a card is: Today, the list, or Earlier Overviews.
enum OverviewPlace {
    case today
    case list
    case earlier
}

/// What a card shows under its header or title, by its state.
private struct OverviewStateContent: View {
    let category: LibraryCategory
    let state: OverviewCardState
    let place: OverviewPlace
    @Environment(OverviewModel.self) private var overviews
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        let name = category.name
        switch state {
        case .done(let overview, let working):
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if working {
                    OverviewWorkingLine(name: name)
                }
                OverviewDoneContent(overview: overview, name: name, place: place, categoryID: category.id)
                Button {
                    overviews.write(category.id)
                } label: {
                    Text("Rewrite")
                        .frame(minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .disabled(working)
                .accessibilityIdentifier(AccessibilityID.overview("rewrite", name))
            }
        case .working:
            OverviewWorkingLine(name: name)
        case .failed(let issue):
            messageAndStep(
                Text(verbatim: OverviewWording.sentence(issue)), part: "issue", step: OverviewWording.step(issue), name: name
            )
        case .noModel:
            messageAndStep(Text("Set up a model to get overviews"), part: "noModel", step: .openSettings, name: name)
        case .write(let count):
            messageAndStep(Text("\(count) new articles, no overview for today yet"), part: "newCount", step: .write, name: name)
        case .nothingNew:
            Text("Nothing new today")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.overview("nothingNew", name))
        case .off:
            EmptyView()
        }
    }

    private func messageAndStep(_ message: Text, part: String, step: OverviewWording.Step, name: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            message
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.overview(part, name))
            Button {
                OverviewSteps.take(step, category: category.id, overviews: overviews, navigation: navigation)
            } label: {
                Text(verbatim: OverviewWording.title(step))
                    .frame(minHeight: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .accessibilityIdentifier(AccessibilityID.overview(step == .write ? "write" : "step", name))
        }
    }
}

/// "Writing overview…" with a small activity mark.
private struct OverviewWorkingLine: View {
    let name: String

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            ProgressView()
                .controlSize(.small)
            Text("Writing overview…")
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.overview("working", name))
    }
}

/// A `done` overview: the summary (six lines on Today, then More), the
/// highlights (three until More), the footnote and the not-verification
/// line (decision 6). On the expanded list card and in Earlier Overviews
/// everything is shown.
struct OverviewDoneContent: View {
    let overview: StoredOverview
    let name: String
    let place: OverviewPlace
    let categoryID: UUID
    /// What a highlight's tap does in Earlier Overviews (the sheet closes
    /// first); `nil` elsewhere.
    var openHighlight: ((OverviewHighlight) -> Void)?
    @Environment(OverviewModel.self) private var overviews
    @State private var fullHeight = 0.0
    @State private var shownHeight = 0.0

    var body: some View {
        let expanded = place != .today || overviews.expandedTodayCards.contains(categoryID)
        let highlights = expanded ? overview.highlights : Array(overview.highlights.prefix(3))
        let truncated = fullHeight > shownHeight + 1 || overview.highlights.count > 3
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            summary(expanded: expanded)
            if !highlights.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(highlights.enumerated()), id: \.offset) { index, highlight in
                        highlightRow(highlight, number: index + 1)
                    }
                }
            }
            if place == .today, expanded || truncated {
                Button {
                    if expanded {
                        overviews.expandedTodayCards.remove(categoryID)
                    } else {
                        overviews.expandedTodayCards.insert(categoryID)
                    }
                } label: {
                    Text(expanded ? "Less" : "More")
                        .frame(minHeight: Theme.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .accessibilityIdentifier(AccessibilityID.overview("more", name))
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                footnote
                    .accessibilityIdentifier(AccessibilityID.overview("footnote", name))
                Text("An overview rests on titles and excerpts only and is not verification.")
                    .accessibilityIdentifier(AccessibilityID.overview("note", name))
            }
            .font(.footnote)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(expanded: Bool) -> some View {
        return modelText(overview.text ?? "", overview.locale)
            .lineLimit(expanded ? nil : 6)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { shownHeight = $0 }
            // The whole summary, unseen, measured to know whether six lines
            // cut it.
            .background(alignment: .topLeading) {
                modelText(overview.text ?? "", overview.locale)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .onGeometryChange(for: Double.self) { $0.size.height } action: { fullHeight = $0 }
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier(AccessibilityID.overview("summary", name))
    }

    private func highlightRow(_ highlight: OverviewHighlight, number: Int) -> some View {
        Button {
            if let openHighlight {
                openHighlight(highlight)
            } else {
                overviews.open(highlight: highlight, category: categoryID, fromToday: place == .today)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                modelText(highlight.text, overview.locale)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Spacing.small)
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.overviewHighlight(number, name))
    }

    private var footnote: Text {
        let model = overview.model ?? ""
        let time = place == .earlier
            ? overview.createdAt.formatted(date: .abbreviated, time: .shortened)
            : overview.createdAt.formatted(date: .omitted, time: .shortened)
        return Text("Written by \(model) from the titles and excerpts of \(overview.articleCount) articles · \(time)")
    }
}

// MARK: - The shell's question

extension View {
    /// The question of a manual overview job that stored nothing, or of a
    /// failed Rewrite: the reason, its step and Cancel. Presented by the
    /// shell beside the translation's questions.
    func overviewDialogs() -> some View {
        modifier(OverviewDialogs())
    }
}

private struct OverviewDialogs: ViewModifier {
    @Environment(OverviewModel.self) private var overviews: OverviewModel?
    @Environment(NavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        let question = overviews?.question
        content.alert(
            Text(verbatim: question.map { OverviewWording.sentence($0.issue) } ?? ""),
            isPresented: Binding {
                overviews?.question != nil
            } set: { shown in
                if !shown {
                    overviews?.question = nil
                }
            },
            presenting: question
        ) { question in
            if let overviews {
                let step = OverviewWording.step(question.issue)
                Button(OverviewWording.title(step)) {
                    OverviewSteps.take(step, category: question.category, overviews: overviews, navigation: navigation)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
