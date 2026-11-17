import NewsPawKit
import SwiftUI

/// Settings (ux S8). Each later issue adds its own row, in the order of
/// the ux table: Models & Translation, Refresh, Reading, Adult Partition,
/// Data, Usage, then About.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                NavigationLink(value: SettingsRoute.models) {
                    Label("Models & Translation", systemImage: "translate")
                }
                .accessibilityIdentifier(AccessibilityID.modelsRow)
                NavigationLink(value: SettingsRoute.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier(AccessibilityID.refreshRow)
                NavigationLink(value: SettingsRoute.reading) {
                    Label("Reading", systemImage: "textformat.size")
                }
                .accessibilityIdentifier(AccessibilityID.readingSettingsRow)
                if model.gateState != .unavailable {
                    adultPartitionRow
                }
                NavigationLink(value: SettingsRoute.data) {
                    Label("Data", systemImage: "externaldrive")
                }
                .accessibilityIdentifier(AccessibilityID.dataRow)
                NavigationLink(value: SettingsRoute.usage) {
                    Label("Usage", systemImage: "chart.bar")
                }
                .accessibilityIdentifier(AccessibilityID.usageRow)
            }
            .listRowBackground(Theme.surface)
            Section {
                NavigationLink(value: SettingsRoute.about) {
                    Label("About", systemImage: "info.circle")
                }
                .accessibilityIdentifier(AccessibilityID.aboutRow)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Settings")
    }
}

extension SettingsView {
    /// Adult Partition (ux S10; RD18 decision 10), present only when the
    /// feature switch is on. Not a link: while the partition is on and
    /// locked, choosing it authenticates before the screen is pushed.
    private var adultPartitionRow: some View {
        Button {
            Task { await model.openAdultSettings() }
        } label: {
            HStack {
                // Drawn as the links beside it are: the icon in the text
                // colour, the chevron in the system's.
                Label("Adult Partition", systemImage: "lock.shield")
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Theme.Spacing.small)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAuthenticating)
        .accessibilityIdentifier(AccessibilityID.adultPartitionRow)
    }
}

/// What a Settings route shows.
struct SettingsDestination: View {
    let route: SettingsRoute

    var body: some View {
        switch route {
        case .models: ModelsView()
        case .modelSlot(let role): ModelSlotForm(role: role)
        case .refresh: RefreshSettingsView()
        case .reading: ReadingSettingsScreen()
        case .adultPartition: AdultPartitionView()
        case .data: DataSettingsView()
        case .usage: UsageView()
        case .about: AboutView()
        }
    }
}

/// Settings → Refresh (ux S8; RD06): the interval and how long articles are
/// kept, each an inline picker whose options are rows, so that at the
/// largest text size every option wraps instead of being cut (a menu
/// picker's value is truncated there, measured). Background refresh arrives
/// with RD24.
struct RefreshSettingsView: View {
    @Environment(RefreshModel.self) private var refresh

    var body: some View {
        @Bindable var refresh = refresh
        List {
            Section {
                Picker("Refresh Interval", selection: $refresh.interval) {
                    Text("Every 15 Minutes").tag(RefreshInterval.fifteenMinutes)
                    Text("Every 30 Minutes").tag(RefreshInterval.thirtyMinutes)
                    Text("Every Hour").tag(RefreshInterval.sixtyMinutes)
                    Text("Manual Only").tag(RefreshInterval.manualOnly)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Refresh Interval")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("When you open the app and this long has passed since the last refresh, the library is refreshed. Pull down on Today to refresh at any time.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker("Keep Articles", selection: $refresh.retention) {
                    Text("7 Days").tag(Retention.sevenDays)
                    Text("30 Days").tag(Retention.thirtyDays)
                    Text("90 Days").tag(Retention.ninetyDays)
                    Text("Forever").tag(Retention.forever)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Keep Articles")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Counted from when an article was first seen. Starred articles are always kept. A change takes effect the next time you open the app.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Refresh")
    }
}

/// Settings → Data (ux S8; RD09 decision 14; RD08): OPML import and export
/// of the current library, the size of its image cache, read each time the
/// screen is shown, and Clear for that cache only. The configuration file
/// arrives with RD20.
struct DataSettingsView: View {
    @Environment(ReadingModel.self) private var reading
    @Environment(SourceModel.self) private var sources
    @State private var size: Int?
    @State private var isClearing = false
    @State private var isExporting = false
    @State private var exported: ExportedFile?
    /// The export the share sheet shows, until its directory is removed.
    @State private var shownExport: URL?
    @State private var exportFailed = false
    /// Whether this screen is shown: an export that ends after it went
    /// away is removed, not presented.
    @State private var isShown = false

    /// The file handed to the share sheet.
    private struct ExportedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        List {
            Section {
                Button {
                    sources.beginOPMLImport(from: .settings)
                } label: {
                    HStack {
                        Text("Import OPML")
                        if sources.opmlImport?.origin == .settings, sources.opmlImport?.stage == .reading {
                            Spacer(minLength: Theme.Spacing.small)
                            ProgressView()
                        }
                    }
                    .frame(minHeight: Theme.minimumTapTarget)
                }
                .disabled(sources.opmlImport?.stage == .reading)
                .accessibilityIdentifier(AccessibilityID.importOPMLButton)
                Button {
                    export()
                } label: {
                    HStack {
                        Text("Export OPML")
                        if isExporting {
                            Spacer(minLength: Theme.Spacing.small)
                            ProgressView()
                        }
                    }
                    .frame(minHeight: Theme.minimumTapTarget)
                }
                // Only feeds and GitHub sources are written.
                .disabled(isExporting || !sources.summaries.contains { $0.kind.isCollectedAsFeed })
                .accessibilityIdentifier(AccessibilityID.exportOPMLButton)
                // On the row, not on the list: the list carries the import's
                // sheet and alert, and two of a kind on one view do not both
                // present.
                .sheet(item: $exported, onDismiss: removeShownExport) { file in
                    ShareSheet(url: file.url) {
                        exported = nil
                        removeShownExport()
                    }
                    .ignoresSafeArea()
                }
                .alert(Text("Could not export"), isPresented: $exportFailed) {
                    Button("OK") {}
                } message: {
                    Text("The file could not be written.")
                }
            } header: {
                Text(verbatim: "OPML")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Import subscriptions from another reader: its folders become categories. Export writes this library's feeds; web pages are not included.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                LabeledContent {
                    Group {
                        if let size {
                            Text(Int64(size), format: .byteCount(style: .file))
                        } else {
                            Text(verbatim: "–")
                        }
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.cacheSize)
                } label: {
                    Text("Image Cache")
                }
                Button {
                    clear()
                } label: {
                    Text("Clear Image Cache")
                        .frame(minHeight: Theme.minimumTapTarget)
                }
                .disabled(size == nil || size == 0 || isClearing)
                .accessibilityIdentifier(AccessibilityID.clearCacheButton)
            } header: {
                Text("Images")
                    .foregroundStyle(Theme.secondaryText)
            } footer: {
                Text("Images of article lists and of articles. Cleared images are fetched again when they are next shown.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Data")
        .onAppear {
            isShown = true
            Task { size = await reading.library.imageCache.size() }
        }
        .onDisappear {
            isShown = false
        }
        .opmlImport(from: .settings)
    }

    /// The share sheet ended, by an activity or by being closed: its
    /// export's directory is removed.
    private func removeShownExport() {
        if let url = shownExport {
            OPMLExportFile.remove(url)
            shownExport = nil
        }
    }

    /// "Export OPML": the library's file is built off the main actor and
    /// written to a directory of its own; the share sheet shows it. A result
    /// that arrives after the workspace was dropped or the screen was left
    /// is removed, not shown.
    private func export() {
        isExporting = true
        let library = sources.library
        Task {
            defer { isExporting = false }
            do {
                let data = try await library.opmlExport()
                let url = try await Task.detached { try OPMLExportFile.write(data, on: Date()) }.value
                guard !sources.isStopped, isShown, exported == nil else {
                    OPMLExportFile.remove(url)
                    return
                }
                shownExport = url
                exported = ExportedFile(url: url)
            } catch {
                if !sources.isStopped {
                    exportFailed = true
                }
            }
        }
    }

    private func clear() {
        isClearing = true
        Task {
            let cache = reading.library.imageCache
            await cache.clear()
            size = await cache.size()
            isClearing = false
        }
    }
}

/// About: the app's version.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent {
                    Text(verbatim: Self.version)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.versionValue)
                } label: {
                    Text("Version")
                }
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("About")
    }

    /// The marketing version and the build number, for example "0.1.0 (1)".
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
