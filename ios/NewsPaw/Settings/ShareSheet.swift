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

/// The exported OPML files: each export in a directory of its own under
/// `OPML Export` in the temporary directory, removed when its share sheet
/// ends; the whole folder is emptied at launch and at every lock of the
/// adult partition. A file holds the addresses of the partition it came
/// from; its name and title do not name the partition.
enum OPMLExportFile {
    static var root: URL {
        FileManager.default.temporaryDirectory.appending(path: "OPML Export", directoryHint: .isDirectory)
    }

    /// Removes every export, whichever partition and screen it came from.
    static func emptyAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `data` as "NewsPaw Feeds <yyyy-MM-dd>.opml" in a new
    /// directory of its own, so that no other export can overwrite or
    /// remove it, and returns its address.
    static func write(_ data: Data, on date: Date) throws -> URL {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The owner's calendar day, not the one in GMT.
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
        let url = directory.appending(path: "NewsPaw Feeds \(day).opml")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Removes the directory of the export at `url`, and nothing else.
    static func remove(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
