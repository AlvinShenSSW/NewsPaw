import NewsPawKit
import SwiftUI

/// What the page translation line offers (RD16 decision 10).
enum PageTranslationStep: Hashable {
    case showOriginal
    case retry
    case retryWithBackup
    case continueTranslating
    case openSettings
}

/// The wording of the page translation line (ux S5, section 4).
enum PageTranslationWording {
    /// The line's sentence.
    static func sentence(_ line: PageTranslationLine) -> String {
        switch line {
        case .translating:
            String(localized: "Translating…")
        case .translated(let locale):
            String(localized: "Translated to \(TranslationWording.language(locale))")
        case .failed(let reason, _):
            failed(reason: reason)
        case .didNotRespond:
            failed(String(localized: "The page did not respond"))
        case .paused:
            failed(String(localized: "Translation paused on this long page"))
        case .nothingToTranslate:
            String(localized: "Nothing to translate on this page")
        case .noModel:
            String(localized: "Set up a model to translate")
        case .restoreDidNotRespond:
            String(localized: "The page did not respond")
        }
    }

    /// "Some text could not be translated · ⟨reason⟩".
    private static func failed(_ reason: String) -> String {
        String(localized: "Some text could not be translated · \(reason)")
    }

    private static func failed(reason: PageFailureReason) -> String {
        switch reason {
        case .content(let failure): failed(TranslationWording.sentence(failure))
        case .service(let failure): failed(TranslationWording.sentence(TranslationBlock.service(failure)))
        case .setUp(let failure): failed(TranslationWording.sentence(TranslationBlock.setUp(failure)))
        }
    }

    /// The line's actions, in order. "Open Settings" only where Settings
    /// shows this library's models.
    static func steps(_ line: PageTranslationLine, opensSettings: Bool) -> [PageTranslationStep] {
        switch line {
        case .translating, .translated, .restoreDidNotRespond, .nothingToTranslate(brief: false):
            [.showOriginal]
        case .nothingToTranslate(brief: true):
            []
        case .failed(let reason, let offersBackup):
            switch reason {
            case .setUp: opensSettings ? [.retry, .openSettings] : [.retry]
            case .content, .service: offersBackup ? [.retry, .retryWithBackup] : [.retry]
            }
        case .didNotRespond:
            [.retry]
        case .paused:
            [.continueTranslating]
        case .noModel(let link):
            link ? [.openSettings] : []
        }
    }

    static func title(_ step: PageTranslationStep) -> String {
        switch step {
        case .showOriginal: String(localized: "Show Original")
        case .retry: String(localized: "Retry")
        case .retryWithBackup: String(localized: "Retry with the Backup Model")
        case .continueTranslating: String(localized: "Continue")
        case .openSettings: String(localized: "Open Settings")
        }
    }

    static func identifier(_ step: PageTranslationStep) -> String {
        switch step {
        case .showOriginal: AccessibilityID.pageTranslationShowOriginal
        case .retry: AccessibilityID.pageTranslationRetry
        case .retryWithBackup: AccessibilityID.pageTranslationRetryBackup
        case .continueTranslating: AccessibilityID.pageTranslationContinue
        case .openSettings: AccessibilityID.pageTranslationOpenSettings
        }
    }
}

/// The slim status line of page translation under the browser's top bar
/// (ux S5; RD16 decision 10): the sentence, then its action at the
/// trailing end; with two actions, or at the accessibility sizes, the
/// actions go under the sentence and everything wraps. One element for accessibility, holding
/// its actions as buttons of at least 44 points.
struct PageTranslationLineView: View {
    let line: PageTranslationLine
    let opensSettings: Bool
    let take: (PageTranslationStep) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accent) private var accent

    var body: some View {
        let steps = PageTranslationWording.steps(line, opensSettings: opensSettings)
        let stacked = dynamicTypeSize.isAccessibilitySize || steps.count > 1
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Theme.Spacing.medium))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                if case .translating = line {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else if isFailure {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(verbatim: PageTranslationWording.sentence(line))
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !steps.isEmpty {
                let actions = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(spacing: Theme.Spacing.large))
                actions {
                    ForEach(steps, id: \.self) { step in
                        Button {
                            take(step)
                        } label: {
                            Text(PageTranslationWording.title(step))
                                .font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: Theme.minimumTapTarget)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(accent)
                        .accessibilityIdentifier(PageTranslationWording.identifier(step))
                    }
                }
                .fixedSize(horizontal: !stacked, vertical: false)
            }
        }
        .padding(.horizontal, Theme.Spacing.standard)
        .padding(.vertical, Theme.Spacing.tight)
        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: PageTranslationWording.sentence(line)))
        .accessibilityIdentifier(AccessibilityID.pageTranslationLine)
    }

    private var isFailure: Bool {
        switch line {
        case .failed, .didNotRespond, .paused, .restoreDidNotRespond: true
        default: false
        }
    }
}
