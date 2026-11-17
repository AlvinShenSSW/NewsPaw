import NewsPawKit
import SwiftUI

/// What a question's step does (RD14 decisions 9 and 10).
@MainActor
enum TranslationSteps {
    static func take(_ step: TranslationWording.Step, for question: TranslationQuestion, translation: TranslationModel, navigation: NavigationModel) {
        translation.question = nil
        switch step {
        case .retry:
            translation.retry(question.article, backup: false)
        case .retryWithBackup:
            translation.retry(question.article, backup: true)
        case .openSettings:
            navigation.openModelSettings()
        }
    }
}

extension View {
    /// The question of a row's warning mark, or of a retry that stored
    /// nothing: the reason's sentence, its next steps and Cancel. Presented
    /// by the shell, so that one question is up at a time.
    func translationDialogs() -> some View {
        modifier(TranslationDialogs())
    }
}

private struct TranslationDialogs: ViewModifier {
    @Environment(TranslationModel.self) private var translation: TranslationModel?
    @Environment(NavigationModel.self) private var navigation

    func body(content: Content) -> some View {
        let question = translation?.question
        content.alert(
            Text(verbatim: question.map(TranslationWording.sentence) ?? ""),
            isPresented: Binding {
                translation?.question != nil
            } set: { shown in
                if !shown {
                    translation?.question = nil
                }
            },
            presenting: question
        ) { question in
            if let translation {
                ForEach(TranslationWording.steps(for: question, hasBackup: translation.hasBackup), id: \.self) { step in
                    Button(TranslationWording.title(step)) {
                        TranslationSteps.take(step, for: question, translation: translation, navigation: navigation)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
