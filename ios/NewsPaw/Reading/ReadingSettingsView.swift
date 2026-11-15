import NewsPawKit
import SwiftUI

/// The three reading settings (ux S4, S8; RD11 decision 10): text size in
/// five steps, line spacing, typeface. The same list behind "Aa" on the
/// reading screen and in Settings › Reading; a change applies at once and
/// is stored. Line spacing and typeface are inline pickers whose options
/// are rows, so that every option wraps at the largest text size.
struct ReadingSettingsView: View {
    @Environment(ReadingSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                textSize
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker("Line Spacing", selection: $settings.lineSpacing) {
                    Text("Compact").tag(ReadingLineSpacing.compact)
                        .accessibilityIdentifier(AccessibilityID.lineSpacingOption(ReadingLineSpacing.compact.rawValue))
                    Text("Standard").tag(ReadingLineSpacing.standard)
                        .accessibilityIdentifier(AccessibilityID.lineSpacingOption(ReadingLineSpacing.standard.rawValue))
                    Text("Relaxed").tag(ReadingLineSpacing.relaxed)
                        .accessibilityIdentifier(AccessibilityID.lineSpacingOption(ReadingLineSpacing.relaxed.rawValue))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Line Spacing")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
            Section {
                Picker("Typeface", selection: $settings.typeface) {
                    Text("Sans Serif").tag(ReadingTypeface.sansSerif)
                        .accessibilityIdentifier(AccessibilityID.typefaceOption(ReadingTypeface.sansSerif.rawValue))
                    Text("Serif").tag(ReadingTypeface.serif)
                        .accessibilityIdentifier(AccessibilityID.typefaceOption(ReadingTypeface.serif.rawValue))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Typeface")
                    .foregroundStyle(Theme.secondaryText)
            }
            .listRowBackground(Theme.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Text size: a smaller and a larger button around the five steps.
    private var textSize: some View {
        let steps = ReadingTextSize.allCases
        let index = steps.firstIndex(of: settings.textSize) ?? 0
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.medium) {
                Text("Text Size")
                Spacer(minLength: Theme.Spacing.small)
                sizeControl(steps: steps, index: index)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Text Size")
                sizeControl(steps: steps, index: index)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func sizeControl(steps: [ReadingTextSize], index: Int) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                settings.textSize = steps[index - 1]
            } label: {
                Label("Smaller", systemImage: "textformat.size.smaller")
                    .labelStyle(.iconOnly)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .disabled(index == 0)
            .accessibilityIdentifier(AccessibilityID.textSizeSmallerButton)
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(steps.indices, id: \.self) { step in
                    Circle()
                        .fill(step == index ? Theme.accent : Theme.hairline)
                        .frame(width: 8, height: 8)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Text Size"))
            .accessibilityValue(Text(verbatim: "\(index + 1) / \(steps.count)"))
            .accessibilityIdentifier(AccessibilityID.textSizeValue)
            Button {
                settings.textSize = steps[index + 1]
            } label: {
                Label("Larger", systemImage: "textformat.size.larger")
                    .labelStyle(.iconOnly)
                    .frame(width: Theme.minimumTapTarget, height: Theme.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .disabled(index == steps.count - 1)
            .accessibilityIdentifier(AccessibilityID.textSizeLargerButton)
        }
        // Two buttons in one row: each takes its own tap.
        .buttonStyle(.borderless)
        .foregroundStyle(.tint)
    }
}

/// The reading settings behind "Aa": a popover, or a sheet in compact
/// width, with its title and Close.
struct ReadingSettingsPopover: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ReadingSettingsView()
                .stackBackground(Theme.groupedBackground)
                .navigationTitle("Reading Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            dismiss()
                        }
                        .accessibilityIdentifier(AccessibilityID.readingSettingsCloseButton)
                    }
                }
        }
        .frame(minWidth: 340, minHeight: 440)
        .presentationDetents([.medium, .large])
        .tint(Theme.accent)
        .foregroundStyle(Theme.text)
    }
}

/// Settings › Reading.
struct ReadingSettingsScreen: View {
    var body: some View {
        ReadingSettingsView()
            .stackBackground(Theme.groupedBackground)
            .navigationTitle("Reading")
    }
}
