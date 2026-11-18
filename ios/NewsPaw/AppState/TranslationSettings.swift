import Foundation
import NewsPawKit
import Observation

/// The four translation settings of Settings › Models & Translation (spec
/// N06; RD14 decision 1; RD15 decision 1): the reading language, whether
/// titles are translated automatically, whether an article is translated
/// when it opens, and whether a list row shows the original title too. Global settings over the preferences store, one object for
/// the app, shared by every workspace as the refresh settings are (RD18
/// decision 3). A change applies at once and is stored; the translation
/// and overview models listening are told.
@MainActor @Observable
final class TranslationSettings {
    var readingLocale: ReadingLocale {
        didSet {
            guard readingLocale != oldValue else { return }
            preferences.readingLocale = readingLocale
            for listener in listeners {
                listener.model?.readingLocaleChanged()
            }
            for listener in overviewListeners {
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

    private struct OverviewListener {
        weak var model: OverviewModel?
    }

    /// The overview models told of a change of the reading language (RD23
    /// decision 12).
    @ObservationIgnored private var overviewListeners: [OverviewListener] = []

    init(preferences: Preferences) {
        self.preferences = preferences
        readingLocale = preferences.readingLocale
        translatesTitlesAutomatically = preferences.autoTranslateTitles
        showsOriginalTitles = preferences.showOriginalTitles
        translatesBodyOnOpen = preferences.translatesBodyOnOpen
    }

    /// Reads the preferences again after a configuration import wrote
    /// them (RD20 decision 7): a changed value acts as a change made in
    /// Settings, and the translation models are told.
    func reload() {
        let locale = preferences.readingLocale
        let automatic = preferences.autoTranslateTitles
        let original = preferences.showOriginalTitles
        let bodyOnOpen = preferences.translatesBodyOnOpen
        if locale != readingLocale {
            readingLocale = locale
        }
        if automatic != translatesTitlesAutomatically {
            translatesTitlesAutomatically = automatic
        }
        if original != showsOriginalTitles {
            showsOriginalTitles = original
        }
        // RD15's switch (batch 3): BodyTranslationModel reads it at each
        // opening.
        if bodyOnOpen != translatesBodyOnOpen {
            translatesBodyOnOpen = bodyOnOpen
        }
    }

    /// `model` is told of changes until it is gone.
    func addListener(_ model: TranslationModel) {
        listeners.removeAll { $0.model == nil }
        listeners.append(Listener(model: model))
    }

    /// `model` is told of a change of the reading language until it is gone.
    func addListener(_ model: OverviewModel) {
        overviewListeners.removeAll { $0.model == nil }
        overviewListeners.append(OverviewListener(model: model))
    }
}
