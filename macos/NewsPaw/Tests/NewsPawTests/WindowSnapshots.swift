import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NewsPaw

/// Renders the real main window against an isolated backend into PNG files, without screen
/// recording permission. Runs only when both variables are set, e.g.
///
///     NEWSPAW_UI_SOCKET=/tmp/np-ui.x/control.sock NEWSPAW_UI_SNAPSHOTS=/tmp/shots swift test --filter Snapshots
private let environment = ProcessInfo.processInfo.environment

@Test(.enabled(if: environment["NEWSPAW_UI_SOCKET"] != nil && environment["NEWSPAW_UI_SNAPSHOTS"] != nil))
@MainActor func windowSnapshotsForEveryPageLanguageAndAppearance() async throws {
    let socket = try #require(environment["NEWSPAW_UI_SOCKET"])
    let folder = URL(fileURLWithPath: try #require(environment["NEWSPAW_UI_SNAPSHOTS"]), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let pages = (environment["NEWSPAW_UI_PAGES"]?.split(separator: ",").compactMap { Page(rawValue: String($0)) })
        ?? Page.allCases
    for language in AppLanguage.allCases {
        let name = "NewsPawSnapshots-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(language.rawValue, forKey: "displayLanguage")
        let model = AppModel(socket: LocalSocket(path: socket), defaults: defaults)
        await model.refresh()
        #expect(model.connection == .connected)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            if environment["NEWSPAW_UI_SETUP"] != nil {
                for step in OnboardingData.Step.allCases {
                    let image = try await render(OnboardingWindow(model: model, step: step), appearance: appearance, size: NSSize(width: 760, height: 580))
                    let suffix = appearance == .aqua ? "light" : "dark"
                    try image.write(to: folder.appendingPathComponent("setup-\(step.rawValue + 1)-\(language.rawValue)-\(suffix).png"))
                }
            }
            for page in pages {
                model.page = page
                let image = try await render(MainWindow(model: model), appearance: appearance)
                let suffix = appearance == .aqua ? "light" : "dark"
                try image.write(to: folder.appendingPathComponent("\(page.rawValue)-\(language.rawValue)-\(suffix).png"))
                // The digests page again with its first digest open for editing.
                if page == .digests, let config = model.config, let first = config.subscriptions.first(where: \.enabled) ?? config.subscriptions.first {
                    let open = ScrollView { DigestsPage(model: model, config: config, expanded: first.id).padding(24) }
                        .background(Color(nsColor: .windowBackgroundColor))
                    let image = try await render(open, appearance: appearance)
                    try image.write(to: folder.appendingPathComponent("digests-open-\(language.rawValue)-\(suffix).png"))
                }
            }
        }
    }
}

@MainActor
private func render<Content: View>(_ content: Content, appearance: NSAppearance.Name, size: NSSize = NSSize(width: 1180, height: 820)) async throws -> Data {
    let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
    }
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw BackendFailure.invalidReply
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BackendFailure.invalidReply }
    return png
}
