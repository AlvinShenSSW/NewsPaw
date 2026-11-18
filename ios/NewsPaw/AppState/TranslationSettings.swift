import Foundation
import NewsPawKit
import Observation

/// The three translation settings of Settings › Models & Translation (spec
/// N06; RD14 decision 1): the reading language, whether titles are
/// translated automatically, and whether a list row shows the original
/// title too. Global settings over the preferences store, one object for
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
    }

    /// Reads the preferences again after a configuration import wrote
    /// them (RD20 decision 7): a changed value acts as a change made in
    /// Settings, and the translation models are told.
    func reload() {
        let locale = preferences.readingLocale
        let automatic = preferences.autoTranslateTitles
        let original = preferences.showOriginalTitles
        if locale != readingLocale {
            readingLocale = locale
        }
        if automatic != translatesTitlesAutomatically {
            translatesTitlesAutomatically = automatic
        }
        if original != showsOriginalTitles {
            showsOriginalTitles = original
        }
    }

    /// `model` is told of changes until it is gone.
    func addListener(_ model: TranslationModel) {
        listeners.removeAll { $0.model == nil }
        listeners.append(Listener(model: model))
    }
}
