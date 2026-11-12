import NewsPawKit
import SwiftUI

/// A source under its expanded category (ux S2): a monogram tile, or a globe
/// for a web page; the name; the unread count of a feed-like source, a
/// pause mark when paused, a warning mark and the status sentence when
/// failing. State is carried by a glyph and a VoiceOver value, never by
/// colour or dimming alone. A tap opens Source settings; the menu offers
/// Source settings, Pause or Resume, and Delete.
struct SourceRow: View {
    let source: SourceSummary
    let presentSheet: (() -> Void) -> Void
    @Environment(SourceModel.self) private var sources
    @ScaledMetric private var tileSize = 28.0

    private var isFailing: Bool {
        if case .failing = source.status { true } else { false }
    }

    var body: some View {
        Button {
            presentSheet { sources.beginSettings(source.id) }
        } label: {
            HStack(spacing: Theme.Spacing.medium) {
                tile
                    .opacity(source.paused ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: source.name)
                        .foregroundStyle(source.paused ? Theme.secondaryText : Theme.text)
                    if isFailing, let status = source.status {
                        SourceWording.status(status)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer(minLength: Theme.Spacing.small)
                trailing
            }
            // Aligned with the category's label, after the disclosure
            // control.
            .padding(.leading, Theme.minimumTapTarget)
            .frame(minHeight: Theme.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: source.name))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.sourceRow(source.name))
        .contextMenu {
            Button("Source Settings", systemImage: "gearshape") {
                presentSheet { sources.beginSettings(source.id) }
            }
            if source.isFeedLike {
                if source.paused {
                    Button("Resume", systemImage: "play") { sources.setPaused(source.id, false) }
                } else {
                    Button("Pause", systemImage: "pause") { sources.setPaused(source.id, true) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                sources.requestDeletion(source.id)
            }
        }
    }

    @ViewBuilder
    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                .fill(Theme.groupedBackground)
            RoundedRectangle(cornerRadius: Theme.Radius.thumbnail)
                .strokeBorder(Theme.hairline)
            if source.isFeedLike {
                Text(verbatim: monogram)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Image(systemName: "globe")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .accessibilityHidden(true)
    }

    private var monogram: String {
        source.name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    @ViewBuilder
    private var trailing: some View {
        if source.paused {
            Image(systemName: "pause.circle")
                .foregroundStyle(Theme.secondaryText)
        } else if isFailing {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.secondaryText)
        } else if source.isFeedLike, source.unreadCount > 0 {
            Text(source.unreadCount, format: .number)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var accessibilityValue: Text {
        if !source.isFeedLike {
            return Text("Web page")
        }
        if source.paused {
            return Text("Paused")
        }
        if isFailing, let status = source.status {
            return SourceWording.status(status)
        }
        return Text("\(source.unreadCount) unread")
    }
}
