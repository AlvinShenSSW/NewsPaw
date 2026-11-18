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

/// The exported files the share sheet is given (RD08 decision 7; RD20
/// decision 9 and review round 2): each export in a directory of its own
/// under the folder's name in the temporary directory, so that no other
/// export — of this workspace or of the other one, a late one of a dropped
/// workspace included — can overwrite or remove it. A directory is removed
/// when its share sheet ends, or when its export is not shown; each folder
/// is emptied at launch and at every lock of the adult partition. A file's
/// name never names the partition it came from.
struct ExportFolder {
    /// "NewsPaw Feeds <yyyy-MM-dd>.opml" (RD08).
    static let opml = ExportFolder(name: "OPML Export", fileName: "NewsPaw Feeds", fileExtension: "opml")
    /// "NewsPaw Configuration <yyyy-MM-dd>.newspaw" (RD20).
    static let configuration = ExportFolder(name: "Configuration", fileName: "NewsPaw Configuration", fileExtension: "newspaw")

    let name: String
    let fileName: String
    let fileExtension: String

    var root: URL {
        FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// Removes every export of this folder, whichever partition and screen
    /// it came from.
    func emptyAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `data` as "<file name> <yyyy-MM-dd>.<extension>" in a new
    /// directory of its own and returns its address; a write that fails
    /// leaves nothing.
    func write(_ data: Data, on date: Date) throws -> URL {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The owner's calendar day, not the one in GMT.
        let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
        let url = directory.appending(path: "\(fileName) \(day).\(fileExtension)")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    /// Removes the directory of the export at `url`, and nothing else.
    func remove(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
