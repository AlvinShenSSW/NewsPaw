import Foundation
import NewsPawKit

/// The wording of translation (ux section 4; RD14 decision 9). No internal
/// word (slot, batch, pause) is shown.
enum TranslationWording {
    /// A reading language's name in the interface language.
    static func language(_ locale: ReadingLocale) -> String {
        switch locale {
        case .simplifiedChinese: String(localized: "Simplified Chinese")
        case .english: String(localized: "English")
        case .japanese: String(localized: "Japanese")
        }
    }

    /// The sentence of a stored failure.
    static func sentence(_ failure: TranslationFailure) -> String {
        switch failure {
        case .refused: String(localized: "The model declined to translate this")
        case .cutOff, .malformed, .count, .empty, .length: String(localized: "The reply could not be used")
        case .badRequest: String(localized: "The service did not accept the request")
        }
    }

    /// The sentence of a block.
    static func sentence(_ block: TranslationBlock) -> String {
        switch block {
        case .service(.limited): String(localized: "The service is limiting requests. Try again later")
        case .service: String(localized: "Could not reach the service")
        case .storage: String(localized: "The change could not be saved.")
        case .setUp(.keyRejected): String(localized: "The service rejected the key")
        case .setUp(.modelNotFound): String(localized: "The service does not have this model")
        case .setUp: String(localized: "Set up a model to translate")
        case .dailyLimit: String(localized: "Today's automatic limit is reached. Translate manually, or raise the limit in Settings")
        case .failedBatch(let failure): sentence(failure)
        }
    }

    static func sentence(_ question: TranslationQuestion) -> String {
        switch question {
        case .failed(_, let failure): sentence(failure)
        case .blocked(_, let block): sentence(block)
        }
    }

    /// The next step a question offers (ux section 4: every failure message
    /// is followed by its next step).
    enum Step: Equatable {
        case retry
        case retryWithBackup
        case openSettings
    }

    static func steps(for question: TranslationQuestion, hasBackup: Bool) -> [Step] {
        switch question {
        case .failed(_, let failure):
            failure == .refused && hasBackup ? [.retry, .retryWithBackup] : [.retry]
        case .blocked(_, let block):
            switch block {
            case .setUp: [.openSettings]
            case .service, .storage, .dailyLimit, .failedBatch: [.retry]
            }
        }
    }

    static func title(_ step: Step) -> String {
        switch step {
        case .retry: String(localized: "Retry")
        case .retryWithBackup: String(localized: "Retry with the Backup Model")
        case .openSettings: String(localized: "Open Settings")
        }
    }
}

extension ArticleRow {
    /// What a row shows in place of its title (decision 9): the translated
    /// title of a `done` row; for an article without a title, the first
    /// line of the translated excerpt; else `nil`, and the original shows.
    var translatedTitle: String? {
        guard let translation, translation.state == .done else { return nil }
        if let title = translation.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard !hasTitle, let line = translation.excerpt?.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty
        else { return nil }
        return line
    }
}
