/// The fixed set of icons a category can use (spec N02; ux.md: SF Symbols,
/// outline style). The raw value is the SF Symbol name, which is what the
/// database stores, so existing raw values must not change.
public enum CategoryIcon: String, Sendable, CaseIterable {
    case folder = "folder"
    case globe = "globe"
    case globeAsia = "globe.asia.australia"
    case globeAmericas = "globe.americas"
    case globeEurope = "globe.europe.africa"
    case newspaper = "newspaper"
    case building = "building.columns"
    case briefcase = "briefcase"
    case chart = "chart.line.uptrend.xyaxis"
    case cpu = "cpu"
    case laptop = "laptopcomputer"
    case sparkles = "sparkles"
    case flask = "flask"
    case leaf = "leaf"
    case heart = "heart"
    case book = "book"
    case film = "film"
    case musicNote = "music.note"
    case gameController = "gamecontroller"
    case paintPalette = "paintpalette"
    case forkKnife = "fork.knife"
    case airplane = "airplane"
    case star = "star"
}
