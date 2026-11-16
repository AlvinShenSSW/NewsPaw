import NewsPawKit
import SwiftUI

/// A step of the first run (ux S12).
enum FirstRunStep: Int {
    case language = 1
    case model = 2
    case sources = 3
}

/// The first run (ux S12; RD21 decisions 1, 3–6 and 8), shown by the shell
/// in place of its containers: Reading Language, Translation Model and
/// Sources, each skippable. One navigation stack on the Settings path, as
/// the containers have (their stacks are not in the hierarchy meanwhile),
/// so that step 2 pushes RD13's model form unchanged; the step changes the
/// stack's root in place. The shell's sheet and dialogs present Add source
/// and the category model's alert as they do over the containers.
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(NavigationModel.self) private var navigation
    @Environment(TranslationSettings.self) private var translation
    @State private var step = FirstRunStep.language
    /// Step 1's choice, preselected from the system's languages; stored
    /// only by Continue.
    @State private var language = ReadingLocale.preselected(from: Locale.preferredLanguages)
    /// Step 3's ticked suggested categories, not yet created.
    @State private var ticked: Set<SuggestedSourceGroup> = []
    /// Whether step 3 is creating the ticked categories.
    @State private var isCreating = false
    @Environment(CategoryModel.self) private var categories
    @Environment(SourceModel.self) private var sources

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.settingsPath) {
            content
                .navigationDestination(for: SettingsRoute.self) { route in
                    SettingsDestination(route: route)
                }
        }
        .accessibilityIdentifier(AccessibilityID.firstRun)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .language:
            FirstRunLanguageStep(language: $language)
                .firstRunStep(.language, primary: Text("Continue"), isBusy: false, primaryAction: {
                    translation.readingLocale = language
                    step = .model
                }, skip: { step = .model }, back: nil)
        case .model:
            FirstRunModelStep()
                .firstRunStep(.model, primary: Text("Continue"), isBusy: false, primaryAction: {
                    step = .sources
                }, skip: { step = .sources }, back: { step = .language })
        case .sources:
            FirstRunSourcesStep(ticked: $ticked, isCreating: isCreating) {
                Task {
                    // Created first, so that Add source's category picker
                    // offers them (decision 6).
                    if await createTicked() {
                        sources.beginAddSource()
                    }
                }
            }
            .firstRunStep(.sources, primary: Text("Done"), isBusy: isCreating, primaryAction: {
                Task {
                    if await createTicked() {
                        model.finishFirstRun()
                    }
                }
            }, skip: { model.finishFirstRun() }, back: { step = .model })
        }
    }

    /// Creates the ticked suggested categories, in the list's order, through
    /// the category model's queue (decision 6): named in the interface
    /// language, with their icons. One whose name a category has already is
    /// not created again. A failed creation stops here with the category
    /// model's alert, and the first run stays.
    private func createTicked() async -> Bool {
        guard !isCreating else { return false }
        isCreating = true
        defer { isCreating = false }
        for group in SuggestedSourceGroup.allCases where ticked.contains(group) {
            let name = SourceWording.groupName(group)
            if !categories.summaries.contains(where: { $0.category.name == name }) {
                guard await categories.createCategory(name: name, icon: group.icon) != nil else { return false }
            }
            ticked.remove(group)
        }
        return true
    }
}

/// The bar and the bottom button every step has: the step's title, "Step
/// N of 3", Skip at the bar's trailing end, Back on steps 2 and 3, and the
/// primary button (Continue, or Done on the last step).
private struct FirstRunStepFrame: ViewModifier {
    @Environment(\.accent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let step: FirstRunStep
    let primary: Text
    let isBusy: Bool
    let primaryAction: () -> Void
    let skip: () -> Void
    let back: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // At most 640 pt wide on iPad, centred (decision 1).
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button(action: primaryAction) {
                    primary
                        .font(.headline)
                        .foregroundStyle(Theme.onAccent)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(accent)
                .disabled(isBusy)
                .accessibilityIdentifier(step == .sources ? AccessibilityID.firstRunDone : AccessibilityID.firstRunContinue)
                .frame(maxWidth: 640 - 2 * Theme.Spacing.standard)
                .padding(.horizontal, Theme.Spacing.standard)
                .padding(.vertical, Theme.Spacing.small)
            }
            .background(Theme.groupedBackground)
            .navigationTitle(title)
            // At the accessibility sizes a large title is cut on iPhone; the
            // inline title is not enlarged and fits (as on Models &
            // Translation).
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                if let back {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: back) {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(isBusy)
                        .accessibilityIdentifier(AccessibilityID.firstRunBack)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip", action: skip)
                        .disabled(isBusy)
                        .accessibilityIdentifier(AccessibilityID.firstRunSkip)
                }
            }
    }

    private var title: Text {
        switch step {
        case .language: Text("Reading Language")
        case .model: Text("Translation Model")
        case .sources: Text("Sources")
        }
    }
}

extension View {
    fileprivate func firstRunStep(
        _ step: FirstRunStep, primary: Text, isBusy: Bool, primaryAction: @escaping () -> Void,
        skip: @escaping () -> Void, back: (() -> Void)?
    ) -> some View {
        modifier(FirstRunStepFrame(step: step, primary: primary, isBusy: isBusy, primaryAction: primaryAction, skip: skip, back: back))
    }
}

/// The top of a step's list: "Step N of 3" and what the step is about,
/// on the grouped background.
struct FirstRunHeader<Leading: View>: View {
    let step: FirstRunStep
    let text: Text
    @ViewBuilder var leading: Leading

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                leading
                Text("Step \(step.rawValue) of 3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.firstRunStep)
                text
                    .font(.body)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.firstRunText)
            }
            .listRowBackground(Color.clear)
            // In line with the section headers below, and clear of the
            // row's rounded corners, which clip what reaches them.
            .listRowInsets(EdgeInsets(
                top: 0, leading: Theme.Spacing.standard + Theme.Spacing.tight,
                bottom: 0, trailing: Theme.Spacing.standard + Theme.Spacing.tight
            ))
        }
    }
}

extension FirstRunHeader where Leading == EmptyView {
    init(step: FirstRunStep, text: Text) {
        self.init(step: step, text: text) { EmptyView() }
    }
}
