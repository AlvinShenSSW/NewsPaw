import Foundation
import NewsPawKit
import SwiftUI

/// The words of a source's state (RD05 wording table). Reasons are
/// fragments used after "·", so the English ones are lower case.
enum SourceWording {
    static func reason(_ reason: CollectionFailure?) -> Text {
        switch reason {
        case .unreachable: Text("could not connect")
        case .timedOut: Text("timed out")
        case .gone: Text("the address is gone")
        case .httpStatus(let status): Text("the server answered with error \(status)")
        case .notAFeed: Text("not a recognisable feed")
        case .tooLarge: Text("the response is too large")
        case .tooManyRedirects: Text("too many redirects")
        case .unsupportedAddress: Text("this address cannot be used")
        case nil: Text("something went wrong")
        }
    }

    /// The status sentence of a feed-like source.
    static func status(_ status: SourceStatus) -> Text {
        switch status {
        case .working(let lastSuccess):
            Text("Working · last updated \(namedDay(lastSuccess))")
        case .failing(let reason, let lastSuccess?):
            Text("Could not update · \(Self.reason(reason)) · last worked \(namedDay(lastSuccess))")
        case .failing(let reason, nil):
            Text("Could not update · \(Self.reason(reason))")
        case .paused(let lastSuccess?):
            Text("Paused · last updated \(namedDay(lastSuccess))")
        case .paused(nil):
            Text("Paused")
        case .notUpdatedYet:
            Text("Not updated yet")
        }
    }

    /// The system's named-day style with the time, as in "yesterday at
    /// 21:40".
    static func namedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        // It follows "·" inside a sentence: "today", not "Today".
        formatter.formattingContext = .middleOfSentence
        return formatter.string(from: date)
    }

    /// The system's relative style, as in "25 minutes ago".
    static func relative(_ date: Date) -> Text {
        Text(date, format: .relative(presentation: .named))
    }

    /// A feed format's name; not translated.
    static func format(_ format: ParsedFeed.Format) -> String {
        switch format {
        case .rss, .rdf: "RSS"
        case .atom: "Atom"
        case .json: "JSON Feed"
        }
    }

    /// A repository's feed's name (RD07): the title of its row in Add
    /// source, and part of the kind and of the suggested name.
    static func gitHubFeed(_ feed: GitHubFeed) -> String {
        switch feed {
        case .releases: String(localized: "Releases", comment: "One of a GitHub repository's feeds: its releases (every tag, with the release notes).")
        case .tags: String(localized: "Tags", comment: "One of a GitHub repository's feeds: its tags, without notes.")
        case .commits: String(localized: "Commits", comment: "One of a GitHub repository's feeds: the commits of its default branch.")
        }
    }

    static func group(_ group: SuggestedSourceGroup) -> Text {
        switch group {
        case .world: Text("World")
        case .japan: Text("Japan")
        case .australia: Text("Australia")
        case .china: Text("China")
        case .tech: Text("Tech")
        case .ai: Text("AI")
        }
    }

    /// The message under the address field for an address the normal form
    /// refuses.
    static func addressProblem(_ problem: SourceAddressProblem) -> Text {
        switch problem {
        case .empty: Text("Enter an address.")
        case .unsupportedScheme: Text("Only http and https addresses can be added.")
        case .hasCredentials: Text("Addresses with a user name or password cannot be added.")
        case .malformed: Text("This is not a web address.")
        case .tooLong: Text("This address is too long.")
        }
    }

    /// "This address is already in “⟨category⟩” as “⟨name⟩”."
    static func duplicate(_ existing: ExistingSource) -> Text {
        Text("This address is already in “\(existing.categoryName)” as “\(existing.name)”.")
    }
}
