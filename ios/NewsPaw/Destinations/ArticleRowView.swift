import NewsPawKit
import SwiftUI
import UIKit

extension ArticleRow {
    /// The title a row and the reading screen show (decision 17): the
    /// title, else the first line of the excerpt, else "Untitled".
    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let line = excerpt?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
            return line
        }
        return String(localized: "Untitled")
    }

    /// The link as an address the system can open, when there is one.
    var linkURL: URL? {
        guard let link, let url = URL(string: link), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    /// The relative time a row shows, as in "2 hours ago".
    var relativeTime: String {
        shownAt.formatted(.relative(presentation: .named))
    }
}

/// The words of the read and star actions, the same in the swipes, the
/// row's menu and the reading screen's bar.
enum ArticleActionWording {
    static func star(isStarred: Bool) -> String {
        // "Star" alone is the category icon's name (a shape); the action has
        // a key of its own.
        isStarred ? String(localized: "Unstar") : String(localized: "action.star", defaultValue: "Star", comment: "Stars an article: a swipe, a menu item and a button of the reading screen.")
    }

    static func read(isRead: Bool) -> String {
        isRead ? String(localized: "Mark as Unread") : String(localized: "Mark as Read")
    }
}

/// One article row (ux S3): the unread dot, the title in up to three lines
/// — the translation when there is one, with the original in one secondary
/// line when that setting is on (RD14 decision 9) — the source name and
/// relative time, a star when starred, and the thumbnail on the trailing
/// side, below the text at the accessibility text sizes, unless the
/// library's lists show none (RD19 decision 6). Feed text and
/// model text are shown as plain text. The row is one VoiceOver element
/// whose label holds the unread state, title, source and time, "Starred"
/// when starred, and the translation's state. The label is one language:
/// SwiftUI drops a language given to a run of it (measured, RD14
/// assumption A5).
struct ArticleRowView: View {
    @Environment(\.accent) private var accent
    let row: ArticleRow
    /// The translated title shown in place of the original, or `nil`.
    var translatedTitle: String?
    /// Whether the original title follows a translated one.
    var showsOriginal = false
    /// What the translation's mark says, for the label.
    var mark: TranslationMark?
    @Environment(ReadingModel.self) private var reading
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnail: UIImage?
    /// Puts the dot level with the first line of the title at every size.
    @ScaledMetric(relativeTo: .headline) private var dotOffset = 7.0

    /// The thumbnail's side, in points.
    static let thumbnailSide = 72.0

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Circle()
                .fill(row.isRead ? Color.clear : accent)
                .frame(width: 8, height: 8)
                .padding(.top, dotOffset)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.small))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.medium))
            layout {
                text
                if reading.showsThumbnails, let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .frame(minHeight: Theme.minimumTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        // Keyed on the switch too (RD19 decision 6): turned off, the row
        // lets its picture go and asks for none; turned on, it asks again.
        .task(id: ThumbnailRequest(address: row.imageAddress, shows: reading.showsThumbnails)) {
            await loadThumbnail()
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(verbatim: translatedTitle ?? row.displayTitle)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if translatedTitle != nil, showsOriginal {
                Text(verbatim: row.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                Text(verbatim: "\(row.sourceName) · \(row.relativeTime)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                if row.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if !row.isRead {
            parts.append(String(localized: "Unread"))
        }
        if let translatedTitle {
            parts.append(translatedTitle)
            if showsOriginal {
                parts.append(row.displayTitle)
            }
        } else {
            parts.append(row.displayTitle)
        }
        parts += [row.sourceName, row.relativeTime]
        if row.isStarred {
            parts.append(String(localized: "Starred"))
        }
        switch mark {
        case .working:
            parts.append(String(localized: "Translating…"))
        case .warning(let question):
            parts += [String(localized: "Not translated"), TranslationWording.sentence(question)]
        case nil:
            break
        }
        return parts.joined(separator: ", ")
    }

    /// Fetches the thumbnail through the loader; the row is laid out without
    /// one while it loads or when it is unusable, and nothing animates. A
    /// row that leaves the screen cancels its request.
    private func loadThumbnail() async {
        guard reading.showsThumbnails else {
            thumbnail = nil
            return
        }
        guard let address = row.imageAddress else { return }
        guard let data = await reading.loader.thumbnail(for: address), !Task.isCancelled,
              let image = UIImage(data: data)
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            thumbnail = image
        }
    }
}

/// What a row's thumbnail task is for: the image's address and whether the
/// lists show thumbnails.
private struct ThumbnailRequest: Hashable {
    let address: String?
    let shows: Bool
}
