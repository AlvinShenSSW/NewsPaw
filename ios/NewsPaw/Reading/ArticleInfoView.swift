import NewsPawKit
import SwiftUI

/// Article Info (ux S4; RD15 decision 12): where the body came from, and
/// the title's and the body's translations with their models and times.
struct ArticleInfoView: View {
    let row: ArticleRow
    let content: ReadingContent?
    let key: BodyKey
    @Environment(TranslationModel.self) private var translation: TranslationModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    /// RD14's row: the title's model and time.
    @State private var title: TitleTranslationDetails?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    line(bodySource, identifier: AccessibilityID.articleInfoBody)
                    if let content, content.isExtracted, let fetchedAt = content.fetchedAt {
                        if let host = content.pageAddress?.host(percentEncoded: false) {
                            line(host, identifier: nil)
                        }
                        line(String(localized: "Fetched \(fetchedAt.formatted(date: .abbreviated, time: .shortened))"), identifier: nil)
                    }
                } header: {
                    Text("Body")
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.surface)
                if let translation {
                    Section {
                        line(titleTranslation, identifier: AccessibilityID.articleInfoTitle)
                    } header: {
                        Text("Title Translation")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                    Section {
                        ForEach(Array(bodyTranslation(translation.body).enumerated()), id: \.offset) { index, text in
                            line(text, identifier: index == 0 ? AccessibilityID.articleInfoTranslation : nil)
                        }
                    } header: {
                        Text("Body Translation")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .listRowBackground(Theme.surface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .stackBackground(Theme.groupedBackground)
            .navigationTitle("Article Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier(AccessibilityID.articleInfoDoneButton)
                }
            }
        }
        .tint(accent)
        .foregroundStyle(Theme.text)
        .accessibilityIdentifier(AccessibilityID.articleInfo)
        .task {
            title = await translation?.body.titleDetails(of: row.id)
        }
    }

    private func line(_ text: String, identifier: String?) -> some View {
        Text(verbatim: text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: Theme.minimumTapTarget, alignment: .leading)
            .accessibilityIdentifier(identifier ?? "")
    }

    private var bodySource: String {
        guard let content else { return String(localized: "Only an excerpt is available") }
        if content.isExtracted {
            return String(localized: "Full text from the original page")
        }
        return content.isFullText ? String(localized: "From the feed") : String(localized: "Only an excerpt is available")
    }

    private var titleTranslation: String {
        guard let title, title.state == .done, row.translation?.state == .done else {
            return String(localized: "Not translated")
        }
        guard let model = title.model else {
            return String(localized: "Converted on this device")
        }
        return Self.translatedBy([model], at: title.updatedAt)
    }

    private func bodyTranslation(_ body: BodyTranslationModel) -> [String] {
        // The excerpt filled from RD14's row carries that row's model and
        // time.
        let prefilled = body.isPrefilled(key) ? title.map { BodyTranslationModel.Detail(model: $0.model, at: $0.updatedAt) } : nil
        switch body.summary(of: key, prefilledDetail: prefilled) {
        case .notTranslated:
            return [String(localized: "Not translated")]
        case .converted:
            return [String(localized: "Converted on this device")]
        case .translated(let models, let at):
            return [models.isEmpty ? String(localized: "Converted on this device") : Self.translatedBy(models, at: at)]
        case .partly(let models, let at):
            let partly = String(localized: "Partly translated")
            guard let at, !models.isEmpty else { return [partly] }
            return [partly, Self.translatedBy(models, at: at)]
        }
    }

    /// "Translated by ⟨models⟩ · ⟨time⟩".
    static func translatedBy(_ models: [String], at: Date) -> String {
        let names = models.formatted(.list(type: .and))
        return String(localized: "Translated by \(names)") + " · " + at.formatted(date: .abbreviated, time: .shortened)
    }
}
