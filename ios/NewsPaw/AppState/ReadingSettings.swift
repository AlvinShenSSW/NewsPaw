import NewsPawKit
import Observation

/// The reading screen's three settings (spec N05; RD11 decision 10): text
/// size, line spacing and typeface, over the preferences store. Device
/// settings: one object for the app, the same for every library. A change
/// applies at once to what reads it and is stored.
@MainActor @Observable
final class ReadingSettings {
    var textSize: ReadingTextSize {
        didSet { preferences.readingTextSize = textSize }
    }

    var lineSpacing: ReadingLineSpacing {
        didSet { preferences.readingLineSpacing = lineSpacing }
    }

    var typeface: ReadingTypeface {
        didSet { preferences.readingTypeface = typeface }
    }

    @ObservationIgnored private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
        textSize = preferences.readingTextSize
        lineSpacing = preferences.readingLineSpacing
        typeface = preferences.readingTypeface
    }
}
