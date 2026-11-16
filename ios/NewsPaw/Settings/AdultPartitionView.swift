import NewsPawKit
import SwiftUI

/// Settings › Adult Partition (ux S10; RD18 decision 10). While the
/// partition is off: a short explanation and one switch. While it is on:
/// the lock timing and Turn Off the Adult Partition, whose questions the
/// app model asks at the root. The models, thumbnails, the daily limit and
/// Clear browsing data arrive with RD19.
struct AdultPartitionView: View {
    @Environment(AppModel.self) private var model

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
            Button(role: .destructive) {
                model.askToTurnOff()
            } label: {
                Text("Turn Off the Adult Partition")
                    .frame(minHeight: Theme.minimumTapTarget)
            }
            .accessibilityIdentifier(AccessibilityID.turnOffAdultButton)
        }
        .listRowBackground(Theme.surface)
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
