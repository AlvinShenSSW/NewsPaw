import Foundation
import NewsPawKit

/// The model slots of the normal library and the slot form (ux S8, S9;
/// RD13 decisions 3, 9 and 14). One operation runs at a time — a save, a
/// removal, a Test or a list — and the form's controls are disabled
/// meanwhile. What the form shows lives here, so it survives a container
/// switch; it is set up when the form's route is pushed and dropped when the
/// route leaves the Settings path by any means.
@MainActor @Observable
final class ModelSettingsModel {
    enum LoadState {
        case loading
        case loaded
        case failed
    }

    /// The running Test, or its result for the form it tested.
    enum TestState: Equatable {
        case idle
        case running
        case finished(TestOutcome, TestedForm)
    }

    /// Load List: running, its models (shown in a sheet), or its line.
    enum ListState: Equatable {
        case idle
        case loading
        case loaded([String])
        case failed(TestOutcome)
    }

    /// Which key a Test used.
    enum TestedKey: Equatable {
        case stored
        case typed(SecretKey)
    }

    /// What a Test acted on, so that Save can tell whether the form is
    /// still the tested one.
    struct TestedForm: Equatable {
        let address: String
        let model: String
        let key: TestedKey
    }

    /// An alert of the form.
    enum Alert: Identifiable {
        case saveFailed
        case keyNotSaved
        case keyNotRemoved

        var id: Self { self }
    }

    private(set) var statuses: [ModelRole: ModelSlotStatus] = [:]
    private(set) var loadState = LoadState.loading

    // MARK: Form

    /// The slot whose form is open.
    private(set) var editingRole: ModelRole?
    private(set) var draftPreset = ModelPreset.openAI
    var draftAddress = ""
    var draftModel = ""
    /// A key typed into the secure field. Never filled with the stored key.
    var draftKey = ""
    /// Whether "Replace" was chosen: the stored key is set aside for a new
    /// one until Cancel.
    private(set) var isReplacingKey = false
    private(set) var testState = TestState.idle
    private(set) var listState = ListState.idle
    var isShowingModelList = false
    private(set) var isBusy = false
    var alert: Alert?
    var isAskingToDiscard = false
    var isConfirmingKeyRemoval = false
    var isConfirmingSlotRemoval = false

    /// The form as it was opened, to tell whether anything changed.
    private var original = (preset: ModelPreset.openAI, address: "", model: "")
    /// The running Test or list, cancelled when the form is left. A save or
    /// a removal is not: it finishes (or undoes its key) on its own.
    private var request: Task<Void, Never>?

    private let models: LibraryModels
    private let navigation: NavigationModel

    init(models: LibraryModels, navigation: NavigationModel) {
        self.models = models
        self.navigation = navigation
    }

    // MARK: - Slots

    func reload() async {
        do {
            statuses = try await models.statuses()
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    var hasPrimary: Bool {
        statuses[.primary] != nil
    }

    /// The Settings path changed: a pushed form is set up, a popped one
    /// closed. Its running Test or list is cancelled; a cancelled Test still
    /// writes its usage row and keeps no result.
    func settingsPathChanged(_ path: [SettingsRoute]) {
        let pushed = path.compactMap { route -> ModelRole? in
            if case .modelSlot(let role) = route { role } else { nil }
        }.last
        if let editingRole, pushed != editingRole {
            close()
        }
        if let pushed, pushed != editingRole {
            begin(pushed)
        }
    }

    private func begin(_ role: ModelRole) {
        editingRole = role
        if let saved = statuses[role]?.slot {
            draftPreset = saved.preset
            draftAddress = saved.baseURL
            draftModel = saved.model
        } else {
            draftPreset = .openAI
            draftAddress = ModelPreset.openAI.address
            draftModel = ""
        }
        original = (draftPreset, draftAddress, draftModel)
        draftKey = ""
        isReplacingKey = false
        testState = .idle
        listState = .idle
        isShowingModelList = false
        isAskingToDiscard = false
        isConfirmingKeyRemoval = false
        isConfirmingSlotRemoval = false
        alert = nil
    }

    private func close() {
        request?.cancel()
        request = nil
        editingRole = nil
        draftKey = ""
        testState = .idle
        listState = .idle
        isShowingModelList = false
    }

    /// Leaves the form by popping its route.
    private func leaveForm() {
        guard let role = editingRole else { return }
        navigation.settingsPath.removeAll { $0 == .modelSlot(role) }
    }

    // MARK: - The form's state

    var saved: ModelSlotStatus? {
        editingRole.flatMap { statuses[$0] }
    }

    /// Choosing a preset replaces the address field (decision 6).
    func choosePreset(_ preset: ModelPreset) {
        guard preset != draftPreset else { return }
        draftPreset = preset
        draftAddress = preset.address
    }

    var addressResult: Result<String, ModelAddressProblem> {
        ModelAddress.normalise(draftAddress, allowsLoopbackHTTP: ModelAddress.allowsLoopbackHTTPInThisBuild)
    }

    var modelResult: Result<String, ModelNameProblem> {
        ModelName.validate(draftModel)
    }

    /// The typed key, or why it is refused; `nil` when nothing is typed.
    var typedKey: Result<SecretKey, KeyProblem>? {
        draftKey.isEmpty ? nil : SecretKey.validate(draftKey)
    }

    /// The stored key's last four characters when it is usable: present,
    /// not being replaced, and the form's address keeps the saved address's
    /// origin (decision 3). `.some(nil)` is a short key: only the dots.
    var usableStoredKey: String?? {
        guard !isReplacingKey, let saved, case .present(let lastFour) = saved.key,
              ModelAddress.sameOrigin(saved.slot.baseURL, draftAddress)
        else { return nil }
        return .some(lastFour)
    }

    /// "Key needed": a saved slot with no usable key and nothing typed.
    var showsKeyNeeded: Bool {
        saved != nil && usableStoredKey == nil && !isReplacingKey && draftKey.isEmpty
    }

    private var validTypedKey: SecretKey? {
        if case .success(let key)? = typedKey { key } else { nil }
    }

    private var hasUsableKey: Bool {
        validTypedKey != nil || (usableStoredKey != nil && draftKey.isEmpty)
    }

    private var typedKeyIsRefused: Bool {
        if case .failure? = typedKey { true } else { false }
    }

    var canTest: Bool {
        guard !isBusy, case .success = addressResult, case .success = modelResult else { return false }
        return hasUsableKey && !typedKeyIsRefused
    }

    var canLoadList: Bool {
        guard !isBusy, case .success = addressResult else { return false }
        return hasUsableKey && !typedKeyIsRefused
    }

    var canSave: Bool {
        guard !isBusy, editingRole != nil, case .success = addressResult, case .success = modelResult else { return false }
        if typedKeyIsRefused || (isReplacingKey && draftKey.isEmpty) {
            return false
        }
        return editingRole != .backup || hasPrimary
    }

    var isDirty: Bool {
        draftPreset != original.preset || draftAddress != original.address || draftModel != original.model
            || !draftKey.isEmpty || isReplacingKey
    }

    /// What Test would act on now.
    private var currentForm: TestedForm? {
        guard case .success(let address) = addressResult, case .success(let model) = modelResult else { return nil }
        if let key = validTypedKey {
            return TestedForm(address: address, model: model, key: .typed(key))
        }
        if usableStoredKey != nil, draftKey.isEmpty {
            return TestedForm(address: address, model: model, key: .stored)
        }
        return nil
    }

    /// The line under Test: running, this form's result, the saved result
    /// when the form is still the saved one, or `nil` for "Not tested".
    var testLine: TestOutcome? {
        if case .finished(let outcome, let form) = testState, form == currentForm {
            return outcome
        }
        guard let saved = saved?.slot, let form = currentForm, form.key == .stored,
              form.address == saved.baseURL, form.model == saved.model
        else { return nil }
        return saved.testOutcome
    }

    var isTesting: Bool {
        testState == .running
    }

    // MARK: - Actions

    private var draft: ModelSlotDraft? {
        guard let role = editingRole else { return nil }
        return ModelSlotDraft(role: role, preset: draftPreset, address: draftAddress, model: draftModel, newKey: validTypedKey)
    }

    func test() {
        guard canTest, let draft, let form = currentForm else { return }
        isBusy = true
        testState = .running
        let models = models
        request = Task {
            defer { isBusy = false }
            do {
                let outcome = try await models.test(draft)
                testState = .finished(outcome, form)
                // A Test of the saved values was kept with the slot.
                await reload()
            } catch {
                testState = .idle
            }
        }
    }

    func loadList() {
        guard canLoadList, let draft else { return }
        isBusy = true
        listState = .loading
        let models = models
        request = Task {
            defer { isBusy = false }
            do {
                let list = try await models.listModels(draft)
                listState = .loaded(list)
                isShowingModelList = true
            } catch let failure as ModelFailure {
                listState = .failed(TestOutcome(failure))
            } catch is CancellationError {
                listState = .idle
            } catch {
                listState = .failed(.couldNotConnect)
            }
        }
    }

    var listedModels: [String] {
        if case .loaded(let list) = listState { list } else { [] }
    }

    func pickModel(_ name: String) {
        draftModel = name
        isShowingModelList = false
    }

    func replaceKey() {
        draftKey = ""
        isReplacingKey = true
    }

    func cancelReplacingKey() {
        draftKey = ""
        isReplacingKey = false
    }

    /// Removes the stored key at once (decision 3's order); the slot stays
    /// at "Key needed".
    func removeKey() {
        guard !isBusy, let role = editingRole else { return }
        isBusy = true
        let models = models
        Task {
            defer { isBusy = false }
            do {
                try await models.removeKey(role)
            } catch {
                alert = .keyNotRemoved
            }
            await reload()
        }
    }

    func save() {
        guard canSave, let draft else { return }
        var tested: TestOutcome?
        if case .finished(let outcome, let form) = testState, form == currentForm {
            tested = outcome
        }
        isBusy = true
        let models = models
        Task {
            defer { isBusy = false }
            do {
                try await models.save(draft, testedOutcome: tested)
                await reload()
                leaveForm()
            } catch ModelSettingsError.keyNotSaved {
                alert = .keyNotSaved
            } catch {
                await reload()
                alert = .saveFailed
            }
        }
    }

    /// Removes the slot: its key first, then the row.
    func removeSlot() {
        guard !isBusy, let role = editingRole else { return }
        isBusy = true
        let models = models
        Task {
            defer { isBusy = false }
            do {
                try await models.removeSlot(role)
                await reload()
                leaveForm()
            } catch ModelSettingsError.keyNotRemoved {
                alert = .keyNotRemoved
            } catch {
                await reload()
                alert = .saveFailed
            }
        }
    }

    /// Cancel: asks before discarding unsaved changes.
    func cancel() {
        if isDirty {
            isAskingToDiscard = true
        } else {
            leaveForm()
        }
    }

    func discard() {
        isAskingToDiscard = false
        leaveForm()
    }
}
