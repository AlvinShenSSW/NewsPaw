import Foundation
import NewsPawKit
import Observation

/// The three translation settings of Settings › Models & Translation (spec
/// N06; RD14 decision 1): the reading language, whether titles are
/// translated automatically, and whether a list row shows the original
/// title too. Global settings over the preferences store, one object for
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
