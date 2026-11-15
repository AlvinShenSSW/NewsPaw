import NewsPawKit
import SwiftUI

/// The partition switch (ux section 2; RD18 decisions 5 and 6): a capsule
/// that names the partition shown and opens a menu with the two
/// partitions, the current one checked. Choosing Adult authenticates;
/// choosing Normal locks. In the adult partition the capsule is filled
/// with the accent and reads "Adult", and a lock button sits next to it,
/// so the partition is told by its label and the lock, not by colour
/// alone. Shown only while the adult partition is turned on; each control
/// is at least 44 pt tall.
struct PartitionSwitch: View {
    /// Run before a choice or the lock button acts: the slide-over sidebar
    /// closes itself.
    var beforeChoice: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.accent) private var accent

    private var isAdult: Bool {
        model.shown?.partition == .adult
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Menu {
                Button {
                    beforeChoice()
                    model.lock()
                } label: {
                    choice(Text("Normal"), isCurrent: !isAdult)
                }
                .accessibilityIdentifier(AccessibilityID.partitionNormalChoice)
                Button {
                    beforeChoice()
                    Task { await model.chooseAdult() }
                } label: {
                    choice(Text("Adult"), isCurrent: isAdult)
                }
                .accessibilityIdentifier(AccessibilityID.partitionAdultChoice)
            } label: {
                capsule
            }
            .disabled(model.isAuthenticating)
            .accessibilityLabel(isAdult ? Text("Partition: Adult") : Text("Partition: Normal"))
            .accessibilityIdentifier(AccessibilityID.partitionSwitch)
            if isAdult {
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
        // In a list row (the sidebar) the row would otherwise be one
        // element as wide as the list: the capsule and the lock button stay
        // two elements of their own size.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func choice(_ name: Text, isCurrent: Bool) -> some View {
        if isCurrent {
            Label {
                name
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            name
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
