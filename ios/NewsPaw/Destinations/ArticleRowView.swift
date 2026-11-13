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

/// One article row (ux S3): the unread dot, the title in up to three lines,
/// the source name and relative time, a star when starred, and the
/// thumbnail on the trailing side — below the text at the accessibility
/// text sizes. Feed text is shown as plain text. The row is one VoiceOver
/// element whose label holds the unread state, title, source and time, and
/// "Starred" when starred.
struct ArticleRowView: View {
    let row: ArticleRow
    @Environment(ReadingModel.self) private var reading
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnail: UIImage?

    /// The thumbnail's side, in points.
    static let thumbnailSide = 72.0

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Circle()
                .fill(row.isRead ? Color.clear : Theme.accent)
                .frame(width: 8, height: 8)
                // Level with the first line of the title.
                .padding(.top, 7)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.small))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.medium))
            layout {
                text
                if let thumbnail {
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
        .task(id: row.imageAddress) {
            await loadThumbnail()
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            Text(verbatim: row.displayTitle)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
                Text(verbatim: "\(row.sourceName) · \(row.relativeTime)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                if row.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
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
        parts += [row.displayTitle, row.sourceName, row.relativeTime]
        if row.isStarred {
            parts.append(String(localized: "Starred"))
        }
        return parts.joined(separator: ", ")
    }

    /// Fetches the thumbnail through the loader; the row is laid out without
    /// one while it loads or when it is unusable, and nothing animates. A
    /// row that leaves the screen cancels its request.
    private func loadThumbnail() async {
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
