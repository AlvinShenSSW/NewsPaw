import NewsPawKit
import SwiftUI

/// Settings › Usage (spec N11; ux S8; RD17 decisions 4 and 5): the
/// requests and tokens of the workspace's own library per model and
/// purpose for today, 7 days or 30 days, and the partition's daily
/// automatic limit. Nothing is converted to money; a token count the
/// service did not return is shown as unknown, never as zero.
struct UsageView: View {
    @Environment(UsageModel.self) private var usage
    /// Today each time the screen is opened; not remembered.
    @State private var period = UsagePeriod.today

    var body: some View {
        @Bindable var usage = usage
        List {
            Section {
                Picker("Period", selection: $period) {
                    Text("Today").tag(UsagePeriod.today)
                    Text("7 Days").tag(UsagePeriod.sevenDays)
                    Text("30 Days").tag(UsagePeriod.thirtyDays)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.usagePeriodPicker)
            }
            .listRowBackground(Theme.surface)
            switch usage.content {
            case .loading:
                EmptyView()
            case .failed:
                Section {
                    readFailure
                }
                .listRowBackground(Theme.surface)
                limitSection {
                    readFailure
                }
            case .loaded(let snapshot):
                usageSections(snapshot)
                limitSection {
                    limitRows(snapshot)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Usage")
        // On each appearance and each change of period.
        .task(id: period) {
            await usage.load(period)
        }
        .alert("The change could not be saved.", isPresented: $usage.isShowingSaveError) {
            Button("OK", role: .cancel) {}
        }
    }

    private var readFailure: some View {
        Text("Usage could not be read.")
            .foregroundStyle(Theme.secondaryText)
            .accessibilityIdentifier(AccessibilityID.usageReadFailed)
    }

    // MARK: - Usage

    @ViewBuilder
    private func usageSections(_ snapshot: UsageModel.Snapshot) -> some View {
        if snapshot.models.isEmpty {
            Section {
                Text("No model requests in this period.")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.usageEmpty)
            } footer: {
                usageFooter
            }
            .listRowBackground(Theme.surface)
        } else {
            ForEach(snapshot.models) { model in
                Section {
                    ForEach(model.totals, id: \.purpose) { total in
                        UsageTotalRow(total: total)
                    }
                } header: {
                    // The model's name as sent: never translated.
                    Text(verbatim: model.model)
                        .textCase(nil)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.usageModel(model.model))
                } footer: {
                    if model.id == snapshot.models.last?.id {
                        usageFooter
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
    }

    private var usageFooter: some View {
        Text("Days begin at midnight on this device. Tokens are counted as each service reported them.")
            .foregroundStyle(Theme.secondaryText)
    }

    // MARK: - The limit

    private func limitSection(@ViewBuilder _ rows: () -> some View) -> some View {
        Section {
            rows()
        } header: {
            Text("Daily Automatic Limit")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("When today's automatic requests reach this number, nothing more is sent automatically until tomorrow. Translations you start yourself are not limited.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private func limitRows(_ snapshot: UsageModel.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text("Automatic requests today: \(snapshot.automaticToday) of \(snapshot.limit)")
                .accessibilityIdentifier(AccessibilityID.usageToday)
            if snapshot.automaticToday >= snapshot.limit {
                Text("Today's automatic limit is reached")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.usageLimitReached)
            }
        }
        // Rows, not a menu, so that at the largest text size every value
        // wraps instead of being cut (as Settings › Refresh).
        Picker("Daily Automatic Limit", selection: limit) {
            ForEach(usage.limitOptions, id: \.self) { value in
                Text(value, format: .number).tag(value)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .disabled(usage.isStoringLimit)
        .accessibilityIdentifier(AccessibilityID.dailyLimitPicker)
    }

    private var limit: Binding<Int> {
        Binding {
            usage.selectedLimit ?? Library.standardDailyAutomaticLimit
        } set: { value in
            let period = period
            Task { await usage.chooseLimit(value, period: period) }
        }
    }
}

/// One purpose of one model: its name, its requests and its tokens.
private struct UsageTotalRow: View {
    let total: UsageTotal

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            purposeName
            Group {
                Text("\(total.requests) requests")
                if total.hasTokens {
                    Text(verbatim: tokens)
                    if total.requestsWithoutTokens > 0 {
                        Text("Tokens unknown for \(total.requestsWithoutTokens) requests")
                    }
                } else {
                    Text("Tokens unknown")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.usageTotal(model: total.model, purpose: total.purpose.rawValue))
    }

    /// The reported input and output tokens, each with the locale's
    /// grouping.
    private var tokens: String {
        let input = String(localized: "\(total.inputTokens) input tokens")
        let output = String(localized: "\(total.outputTokens) output tokens")
        return "\(input) · \(output)"
    }

    private var purposeName: Text {
        switch total.purpose {
        case .titles: Text("Titles and Summaries")
        case .body: Text("Article Text")
        case .page: Text("Web Pages")
        case .overview: Text("Overviews")
        case .test: Text("Model Tests")
        }
    }
}
