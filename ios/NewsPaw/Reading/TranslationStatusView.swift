import NewsPawKit
import SwiftUI

/// The progress line of a body's translation (ux S4; RD15 decision 12): a
/// thin determinate bar and "Translating k of n", in the top inset of the
/// reading screen, one accessibility element.
struct BodyProgressLine: View {
    let progress: BodyProgress
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
                .tint(accent)
            Text("Translating \(progress.finished) of \(progress.total)")
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.vertical, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.94))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Translating \(progress.finished) of \(progress.total)"))
        .accessibilityIdentifier(AccessibilityID.bodyProgress)
    }
}

/// The banner above a body (ux S4; decision 12): the reason, then its
/// steps. It scrolls with the body and has no Close: Retry stays reachable
/// while a failure is stored.
struct BodyBannerView: View {
    let banner: BodyBanner
    let take: (TranslationWording.Step) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityHidden(true)
                Text(verbatim: banner.sentence)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.tight))
                : AnyLayout(HStackLayout(spacing: Theme.Spacing.medium))
            layout {
                ForEach(banner.steps, id: \.self) { step in
                    Button {
                        take(step)
                    } label: {
                        Text(TranslationWording.title(step))
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: Theme.minimumTapTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier(Self.identifier(step))
                }
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.bodyBanner)
    }

    private static func identifier(_ step: TranslationWording.Step) -> String {
        switch step {
        case .retry: AccessibilityID.bodyBannerRetry
        case .retryWithBackup: AccessibilityID.bodyBannerRetryBackup
        case .openSettings: AccessibilityID.bodyBannerOpenSettings
        }
    }
}

/// The bottom bar's translation control (decision 12): Translate, or the
/// display-mode menu: an inline picker of the three modes inside a menu
/// (assumption A6).
struct BodyControlView: View {
    let control: BodyControl
    let mode: ReadingDisplayMode
    let translate: @MainActor () -> Void
    let setMode: @MainActor @Sendable (ReadingDisplayMode) -> Void

    var body: some View {
        switch control {
        case .none:
            EmptyView()
        case .translate:
            Button("Translate", systemImage: "translate", action: translate)
                .accessibilityIdentifier(AccessibilityID.translateButton)
        case .modes:
            Menu {
                Picker(selection: Binding(get: { mode }, set: setMode)) {
                    ForEach(ReadingDisplayMode.allCases, id: \.self) { option in
                        Text(verbatim: DisplayModeWording.title(option))
                            .tag(option)
                            .accessibilityIdentifier(AccessibilityID.displayModeOption(option.rawValue))
                    }
                } label: {
                    Text("Display Mode")
                }
                .pickerStyle(.inline)
            } label: {
                Label("Display Mode", systemImage: DisplayModeWording.symbol(mode))
            }
            .accessibilityValue(Text(verbatim: DisplayModeWording.title(mode)))
            .accessibilityIdentifier(AccessibilityID.displayModeMenu)
        }
    }
}

/// The names and symbols of the display modes.
enum DisplayModeWording {
    static func title(_ mode: ReadingDisplayMode) -> String {
        switch mode {
        // A key of its own: "Translation" alone is the settings section.
        case .translation: String(localized: "displayMode.translation", defaultValue: "Translation", comment: "A display mode: the translated text.")
        case .original: String(localized: "Original")
        case .sideBySide: String(localized: "Side by Side")
        }
    }

    static func symbol(_ mode: ReadingDisplayMode) -> String {
        switch mode {
        case .translation: "character.book.closed"
        case .original: "doc.plaintext"
        case .sideBySide: "rectangle.split.1x2"
        }
    }
}
