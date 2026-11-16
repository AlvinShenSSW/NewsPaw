import Foundation
import NewsPawKit
import Observation

/// The four translation settings of Settings › Models & Translation (spec
/// N06; RD14 decision 1; RD15 decision 1): the reading language, whether
/// titles are translated automatically, whether an article is translated
/// when it opens, and whether a list row shows the original title too. Global settings over the preferences store, one object for
/// the app, shared by every workspace as the refresh settings are (RD18
/// decision 3). A change applies at once and is stored; the translation
/// models listening are told.
@MainActor @Observable
final class TranslationSettings {
    var readingLocale: ReadingLocale {
        didSet {
            guard readingLocale != oldValue else { return }
            preferences.readingLocale = readingLocale
            for listener in listeners {
                listener.model?.readingLocaleChanged()
            }
        }
    }

    var translatesTitlesAutomatically: Bool {
        didSet {
            guard translatesTitlesAutomatically != oldValue else { return }
            preferences.autoTranslateTitles = translatesTitlesAutomatically
            for listener in listeners {
                listener.model?.automaticTranslationChanged()
            }
        }
    }

    var showsOriginalTitles: Bool {
        didSet { preferences.showOriginalTitles = showsOriginalTitles }
    }

    /// "Translate Articles When Opened" (RD15 decision 1): it applies from
    /// the next opening.
    var translatesBodyOnOpen: Bool {
        didSet { preferences.translatesBodyOnOpen = translatesBodyOnOpen }
    }

    /// The configuration a translator works with.
    var configuration: TranslationConfiguration {
        TranslationConfiguration(locale: readingLocale, automatic: translatesTitlesAutomatically)
    }

    @ObservationIgnored private let preferences: Preferences

    private struct Listener {
        weak var model: TranslationModel?
    }

    @ObservationIgnored private var listeners: [Listener] = []

    init(preferences: Preferences) {
        self.preferences = preferences
        readingLocale = preferences.readingLocale
        translatesTitlesAutomatically = preferences.autoTranslateTitles
        showsOriginalTitles = preferences.showOriginalTitles
        translatesBodyOnOpen = preferences.translatesBodyOnOpen
    }

    /// `model` is told of changes until it is gone.
    func addListener(_ model: TranslationModel) {
        listeners.removeAll { $0.model == nil }
        listeners.append(Listener(model: model))
    }
}
