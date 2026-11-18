import NewsPawKit
import SwiftUI

/// The partition switch (ux section 2; RD18 decisions 5 and 6): a capsule
/// that names the partition shown and opens a menu with the two
/// partitions, the current one checked, and, in the adult partition, a
/// lock button next to it. Choosing Adult authenticates; choosing Normal
/// locks. In the adult partition the capsule is filled with the accent and
/// reads "Adult", so the partition is told by its label and the lock, not
/// by colour alone. Shown only while the adult partition is turned on;
/// each control is at least 44 pt tall.
///
/// This is the form for a list row (the sidebar). A navigation bar takes
/// the two controls as two items (`PartitionMenu`, `PartitionLockButton`):
/// one item holding both was drawn as a lone chevron on iPhone (measured).
struct PartitionSwitch: View {
    /// Run before a choice or the lock button acts: the slide-over sidebar
    /// closes itself.
    var beforeChoice: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            PartitionMenu(beforeChoice: beforeChoice)
            if model.shown?.partition == .adult {
                PartitionLockButton(beforeChoice: beforeChoice)
            }
        }
        // In a list row the row would otherwise be one element as wide as
        // the list: the capsule and the lock button stay two elements of
        // their own size.
        .accessibilityElement(children: .contain)
    }
}

/// The capsule and its menu.
struct PartitionMenu: View {
    var beforeChoice: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    private var isAdult: Bool {
        model.shown?.partition == .adult
    }

    var body: some View {
        Menu {
            // A picker, so that the system marks the current partition
            // itself: its checkmark is kept at the largest text sizes,
            // where a menu drops an item's own image (measured), and
            // VoiceOver hears it as selected.
            Picker(selection: choice) {
                Text("Normal")
                    .tag(Partition.normal)
                    .accessibilityIdentifier(AccessibilityID.partitionNormalChoice)
                Text("Adult")
                    .tag(Partition.adult)
                    .accessibilityIdentifier(AccessibilityID.partitionAdultChoice)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            capsule
        }
        .menuStyle(.button)
        .buttonStyle(CapsuleButtonStyle())
        // In the normal partition the only choice is Adult, which is not
        // unlocked while the adult browser's data are cleared or removed
        // (RD19 review rounds 2 and 4): the capsule is dimmed for that time
        // instead of doing nothing. In the adult partition locking stays
        // possible.
        .disabled(model.isAuthenticating || (!isAdult && model.operations.refusesUnlock))
        .accessibilityLabel(isAdult ? Text("Partition: Adult") : Text("Partition: Normal"))
        .accessibilityIdentifier(AccessibilityID.partitionSwitch)
    }

    /// The partition shown; choosing the other one locks, or asks for
    /// authentication. Choosing the one shown changes nothing.
    private var choice: Binding<Partition> {
        Binding {
            isAdult ? .adult : .normal
        } set: { partition in
            beforeChoice()
            switch partition {
            case .normal: model.lock()
            case .adult: Task { await model.chooseAdult() }
            }
        }
    }

    /// "Normal ▾", outlined; "Adult ▾", filled with the accent.
    private var capsule: some View {
        HStack(spacing: Theme.Spacing.tight) {
            (isAdult ? Text("Adult") : Text("Normal"))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .frame(minHeight: Theme.minimumTapTarget)
        .foregroundStyle(isAdult ? Theme.onAccent : Theme.text)
        .background { Capsule().fill(isAdult ? accent : Theme.surface) }
        .overlay {
            if !isAdult {
                Capsule().strokeBorder(Theme.hairline)
            }
        }
        .contentShape(Capsule())
    }
}

/// Draws the menu's label as it is, at its own size. As a bar item a menu
/// with the default style was made 36 pt tall, whatever its label asked
/// for (measured on iPhone).
private struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// The lock button of the adult partition.
struct PartitionLockButton: View {
    var beforeChoice: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    var body: some View {
        Button {
            beforeChoice()
            model.lock()
        } label: {
            Label("Lock", systemImage: "lock")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
                .frame(minWidth: Theme.minimumTapTarget, minHeight: Theme.minimumTapTarget)
                .background { Circle().fill(Theme.surface) }
                .overlay { Circle().strokeBorder(Theme.hairline) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Lock the adult partition"))
        .accessibilityIdentifier(AccessibilityID.lockButton)
    }
}
