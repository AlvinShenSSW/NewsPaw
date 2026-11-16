import Foundation
import SwiftUI
import UIKit

/// The system share sheet for one file. Its completion — an activity
/// finished, or the sheet was closed — is the moment the caller removes the
/// file (RD08 decision 7).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The exported OPML file: one directory of its own under the temporary
/// directory, emptied before each export, when the share sheet closes and at
/// launch. The file holds the addresses of the partition it came from; its
/// name and title do not name the partition.
enum OPMLExportFile {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "OPML Export", directoryHint: .isDirectory)
    }

    /// Removes the directory and whatever is in it.
    static func empty() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes `data` as "NewsPaw Feeds <yyyy-MM-dd>.opml" in an emptied
    /// directory and returns its address.
    static func write(_ data: Data, on date: Date) throws -> URL {
        empty()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The owner's calendar day, not the one in GMT.
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
        let url = directory.appending(path: "NewsPaw Feeds \(day).opml")
        try data.write(to: url, options: .atomic)
        return url
    }
}
