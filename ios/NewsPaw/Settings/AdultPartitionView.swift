import NewsPawKit
import SwiftUI

/// Settings › Adult Partition (ux S10; RD18 decision 10; RD19 decisions 2,
/// 5 and 6). While the partition is off: a short explanation and one
/// switch. While it is on, inside the adult partition: the adult library's
/// primary and backup model, Show Thumbnails in Lists, the lock timing,
/// Clear Browsing Data and Turn Off the Adult Partition. Opened from the
/// normal partition, which never unlocks it (RD18), the rows that live in
/// the adult library are not shown, and a sentence says where they are.
/// The daily automatic limit's row comes with RD17's Usage screen.
struct AdultPartitionView: View {
    @Environment(AppModel.self) private var model
    @Environment(ReadingModel.self) private var reading
    /// The adult library's slots: set only inside the adult partition.
    @Environment(\.partitionModelSettings) private var partitionModels
    @State private var isAskingToClear = false
    /// Said under Clear Browsing Data once a clear has ended, until the
    /// screen is left.
    @State private var browsingDataCleared = false
    @State private var thumbnailsNotSaved = false

    var body: some View {
        List {
            switch model.gateState {
            case .off:
                offContents
            case .locked, .unlocked:
                onContents
            case .unavailable:
                EmptyView()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .navigationTitle("Adult Partition")
        .task { await partitionModels?.reload() }
        .onDisappear { browsingDataCleared = false }
        .alert(Text("Clear the adult partition's browsing data?"), isPresented: $isAskingToClear) {
            Button("Clear", role: .destructive) {
                Task {
                    if await model.clearAdultBrowsingData() {
                        browsingDataCleared = true
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.confirmClearBrowsingDataButton)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cookies, sign-ins and other website data of the adult partition's browser are removed from this device. The normal partition's are kept.")
        }
        .alert("The change could not be saved.", isPresented: $thumbnailsNotSaved) {
            Button("OK") {}
        }
    }

    @ViewBuilder
    private var offContents: some View {
        Section {
            Toggle(isOn: isOn) {
                Text("Adult Partition")
            }
            .disabled(model.isAuthenticating)
            .accessibilityIdentifier(AccessibilityID.adultPartitionToggle)
        } footer: {
            Text("The adult partition is a second, separate library. Its categories, sources and articles are shown only after Face ID, Touch ID or the device passcode, and it locks again when you leave the app.")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier(AccessibilityID.adultExplanation)
        }
        .listRowBackground(Theme.surface)
    }

    /// The switch shows the stored state: it turns on only once the
    /// authentication has passed.
    private var isOn: Binding<Bool> {
        Binding {
            model.gateState != .off
        } set: { on in
            if on {
                Task { await model.turnOnAdult() }
            }
        }
    }

    @ViewBuilder
    private var onContents: some View {
        if let partitionModels {
            ModelSlotsSection(
                primaryID: AccessibilityID.adultPrimaryModelRow, backupID: AccessibilityID.adultBackupModelRow,
                backupNeedsPrimaryID: AccessibilityID.adultBackupNeedsPrimary
            )
            .environment(partitionModels)
            Section {
                Toggle("Show Thumbnails in Lists", isOn: showsThumbnails)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .accessibilityIdentifier(AccessibilityID.showThumbnailsToggle)
            } footer: {
                Text("When off, article lists in the adult partition show no pictures and download none.")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        Section {
            // Rows, not a menu, so that at the largest text size every
            // option wraps instead of being cut (as Settings › Refresh).
            Picker("Lock After Leaving the App", selection: lockTiming) {
                Text("Immediately").tag(LockTiming.immediately)
                Text("After 1 Minute").tag(LockTiming.afterOneMinute)
                Text("After 5 Minutes").tag(LockTiming.afterFiveMinutes)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier(AccessibilityID.lockTimingPicker)
        } header: {
            Text("Lock After Leaving the App")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
        Section {
            Button {
                isAskingToClear = true
            } label: {
                Text("Clear Browsing Data")
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!model.canClearBrowsingData)
            .accessibilityIdentifier(AccessibilityID.clearBrowsingDataButton)
        } footer: {
            if browsingDataCleared {
                Text("Browsing data was cleared.")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.browsingDataCleared)
            }
        }
        .listRowBackground(Theme.surface)
        Section {
            Button(role: .destructive) {
                model.askToTurnOff()
            } label: {
                Text("Turn Off the Adult Partition")
                    .frame(minHeight: Theme.minimumTapTarget)
            }
            .accessibilityIdentifier(AccessibilityID.turnOffAdultButton)
        } footer: {
            if partitionModels == nil {
                Text("The adult partition's models, list thumbnails and daily limit are set inside the adult partition.")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.adultSettingsElsewhere)
            }
        }
        .listRowBackground(Theme.surface)
    }

    /// The switch shows the stored value: it changes once the value was
    /// stored, and a failure says so.
    private var showsThumbnails: Binding<Bool> {
        Binding {
            reading.showsThumbnails
        } set: { shows in
            Task {
                if await !reading.setShowsThumbnails(shows) {
                    thumbnailsNotSaved = true
                }
            }
        }
    }

    private var lockTiming: Binding<LockTiming> {
        Binding {
            model.lockTiming
        } set: { timing in
            model.setLockTiming(timing)
        }
    }
}

extension View {
    /// The adult partition's questions and sentences, at the root (RD18
    /// decisions 9 and 11).
    func adultPartitionDialogs() -> some View {
        modifier(AdultPartitionDialogs())
    }
}

private struct AdultPartitionDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let notice = model.notice
        content
            .alert(
                Text("Turn off the adult partition?"),
                isPresented: asking(.keepOrDelete)
            ) {
                Button("Keep Data Hidden") {
                    Task { await model.turnOff(deletingData: false) }
                }
                Button("Delete Data", role: .destructive) {
                    model.turnOffQuestion = .confirmDelete
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can keep its data hidden on this device, or delete it.")
            }
            .alert(
                Text("Delete everything in the adult partition?"),
                isPresented: asking(.confirmDelete)
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.turnOff(deletingData: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its categories, sources, articles, images and keys are removed from this device. This cannot be undone.")
            }
            .alert(
                notice.map(title) ?? Text(verbatim: ""),
                isPresented: Binding {
                    model.notice != nil
                } set: { presented in
                    if !presented {
                        model.notice = nil
                    }
                },
                presenting: notice
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                if case .couldNotOpen(let failure) = notice {
                    reason(failure)
                }
            }
    }

    /// Whether `question` is the one being asked. An answer that asks the
    /// next question has set it before this one's alert reports closed.
    private func asking(_ question: TurnOffQuestion) -> Binding<Bool> {
        Binding {
            model.turnOffQuestion == question
        } set: { presented in
            if !presented, model.turnOffQuestion == question {
                model.turnOffQuestion = nil
            }
        }
    }

    private func title(_ notice: AdultNotice) -> Text {
        switch notice {
        case .stillLocked: Text("The adult partition is still locked.")
        case .notTurnedOn: Text("The adult partition was not turned on.")
        case .settingsNeedAuthentication: Text("Authentication is needed to open these settings.")
        case .passcodeNeeded: Text("Set a device passcode to use the adult partition.")
        case .couldNotOpen: Text("The adult partition's library could not be opened.")
        case .couldNotDelete: Text("The adult partition's data could not be deleted. Try again.")
        }
    }

    /// The reason sentences of the launch failure screen; never the
    /// error's own text.
    private func reason(_ failure: LibraryFailure) -> Text {
        switch failure {
        case .newerSchema: Text("It was created by a newer version of the app. Update NewsPaw to open it.")
        case .damaged: Text("The library file is damaged or is not a NewsPaw library.")
        case .other: Text("Something went wrong while opening it.")
        }
    }
}
