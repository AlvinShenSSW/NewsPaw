import NewsPawKit
import SwiftUI

/// The form of one model (ux S9; RD13 decisions 6, 9, 14 and 15): service,
/// address, model name with Load List, key, Test with its line, and Remove
/// Model for a saved one. Cancel asks before discarding unsaved changes;
/// Save writes without testing.
struct ModelSlotForm: View {
    let role: ModelRole
    @Environment(ModelSettingsModel.self) private var models
    @FocusState private var focus: Field?

    private enum Field {
        case address
        case model
        case key
    }

    var body: some View {
        @Bindable var models = models
        Form {
            if role == .backup {
                Section {
                    Text("The backup model is used when the primary model fails for network, rate-limit or server reasons.")
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.backupIntro)
                }
                .listRowBackground(Theme.surface)
            }
            serviceSection
            addressSection
            modelSection
            keySection
            testSection
            if models.saved != nil {
                removeSection
            }
        }
        .scrollContentBackground(.hidden)
        .stackBackground(Theme.groupedBackground)
        .foregroundStyle(Theme.text)
        .navigationTitle(ModelWording.role(role))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // Plain bar buttons, as in the other editors.
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    models.cancel()
                }
                .accessibilityIdentifier(AccessibilityID.cancelButton)
                .confirmationDialog("Discard your changes?", isPresented: $models.isAskingToDiscard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) {
                        models.discard()
                    }
                    Button("Keep Editing", role: .cancel) {}
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    focus = nil
                    models.save()
                }
                .disabled(!models.canSave)
                .accessibilityIdentifier(AccessibilityID.saveButton)
            }
        }
        .alert(alertTitle, isPresented: alertPresented) {
            Button("OK") {}
        }
        .sheet(isPresented: $models.isShowingModelList) {
            ModelListSheet()
                .environment(models)
                .tint(Theme.accent)
        }
    }

    // MARK: - Sections
    //
    // The form's text is `Theme.text`, which a button's label takes too:
    // the labels of the actions are tinted, as in Source Settings, so that
    // "Test" does not read like the line under it. The removals stay
    // plain, like "Delete Source".

    private var serviceSection: some View {
        Section {
            Picker("Service", selection: Binding(get: { models.draftPreset }, set: { models.choosePreset($0) })) {
                ForEach(ModelPreset.allCases, id: \.self) { preset in
                    ModelWording.preset(preset)
                        .tag(preset)
                        .accessibilityIdentifier(AccessibilityID.presetOption(preset.rawValue))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .disabled(models.isBusy)
        } header: {
            Text("Service")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("Choosing a service fills in its address.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var addressSection: some View {
        @Bindable var models = models
        return Section {
            TextField("Address", text: $models.draftAddress, prompt: Text(verbatim: "https://"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .address)
                .tappableField { focus = .address }
                .disabled(models.isBusy)
                .accessibilityIdentifier(AccessibilityID.modelAddressField)
            if case .failure(let problem) = models.addressResult, let text = ModelWording.addressProblem(problem) {
                problemLabel(text, identifier: AccessibilityID.modelAddressProblem)
            }
        } header: {
            Text("Address")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var modelSection: some View {
        @Bindable var models = models
        return Section {
            // iOS takes the text field before a secure field for a user
            // name, and offers saved passwords above the keyboard. With a
            // content type of its own the field is not one (see the key
            // field).
            TextField("Model Name", text: $models.draftModel)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($focus, equals: .model)
                .tappableField { focus = .model }
                .disabled(models.isBusy)
                .accessibilityIdentifier(AccessibilityID.modelNameField)
            if case .failure(let problem) = models.modelResult, let text = ModelWording.modelProblem(problem) {
                problemLabel(text, identifier: AccessibilityID.modelNameProblem)
            }
            Button {
                focus = nil
                models.loadList()
            } label: {
                Text("Load List")
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!models.canLoadList)
            .accessibilityIdentifier(AccessibilityID.loadListButton)
            switch models.listState {
            case .loading:
                Text("Loading…")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.loadListLine)
            case .failed(let line):
                ModelWording.testLine(line)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.loadListLine)
            case .idle, .loaded:
                EmptyView()
            }
        } header: {
            Text("Model")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("Type the model's name, or load the list of models the service offers.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var keySection: some View {
        @Bindable var models = models
        return Section {
            if let lastFour = models.usableStoredKey {
                Text(verbatim: lastFour.map { "•••• " + $0 } ?? "••••")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .accessibilityLabel(lastFour.map { Text("Key ending in \($0)") } ?? Text("Key saved"))
                    .accessibilityIdentifier(AccessibilityID.storedKey)
                Button {
                    models.replaceKey()
                    focus = .key
                } label: {
                    Text("Replace")
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(models.isBusy)
                .accessibilityIdentifier(AccessibilityID.replaceKeyButton)
                Button(role: .destructive) {
                    models.isConfirmingKeyRemoval = true
                } label: {
                    Text("Remove")
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(models.isBusy)
                .accessibilityIdentifier(AccessibilityID.removeKeyButton)
                .confirmationDialog("Remove the key?", isPresented: $models.isConfirmingKeyRemoval, titleVisibility: .visible) {
                    Button("Remove Key", role: .destructive) {
                        models.removeKey()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The model stays, and needs a key before it can be used again.")
                }
            } else {
                if models.showsKeyNeeded {
                    Label {
                        Text("Key needed")
                    } icon: {
                        Image(systemName: "key")
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.keyNeeded)
                }
                // Not a password to the system. Left to itself iOS takes a
                // filled secure field for one: when the form closes it
                // offers to save the key in Passwords, which syncs, and
                // that prompt holds every touch meanwhile (seen as an
                // unseen `_SFAppPasswordSavingViewController` in the iOS 27
                // simulator after Replace and Save). A one-time code is
                // never offered for saving, and no saved password is
                // offered for it.
                SecureField("Key", text: $models.draftKey)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .key)
                    .tappableField { focus = .key }
                    .disabled(models.isBusy)
                    .accessibilityIdentifier(AccessibilityID.keyField)
                if case .failure(let problem)? = models.typedKey, let text = ModelWording.keyProblem(problem) {
                    problemLabel(text, identifier: AccessibilityID.keyProblem)
                }
                if models.canCancelReplacingKey {
                    Button {
                        models.cancelReplacingKey()
                        focus = nil
                    } label: {
                        Text("Cancel")
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(models.isBusy)
                    .accessibilityIdentifier(AccessibilityID.cancelReplaceKeyButton)
                }
            }
        } header: {
            Text("Key")
                .foregroundStyle(Theme.secondaryText)
        } footer: {
            Text("Kept in this device's keychain and sent only to this address.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var testSection: some View {
        Section {
            Button {
                focus = nil
                models.test()
            } label: {
                Text("Test")
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!models.canTest)
            .accessibilityIdentifier(AccessibilityID.testButton)
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Group {
                    if models.isTesting {
                        Text("Testing…")
                    } else {
                        ModelWording.testLine(models.testLine)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.testLine)
                if !models.isTesting, let outcome = models.testLine, let sentence = ModelWording.sentence(outcome) {
                    sentence
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier(AccessibilityID.testSentence)
                }
            }
        } footer: {
            Text("Sends one short request with what the form shows. Saving does not test.")
                .foregroundStyle(Theme.secondaryText)
        }
        .listRowBackground(Theme.surface)
    }

    private var removeSection: some View {
        @Bindable var models = models
        let blocked = role == .primary && models.statuses[.backup] != nil
        return Section {
            Button(role: .destructive) {
                models.isConfirmingSlotRemoval = true
            } label: {
                Text("Remove Model")
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(blocked || models.isBusy)
            .accessibilityIdentifier(AccessibilityID.removeModelButton)
            .confirmationDialog("Remove this model?", isPresented: $models.isConfirmingSlotRemoval, titleVisibility: .visible) {
                Button("Remove Model", role: .destructive) {
                    models.removeSlot()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its key is removed from this device.")
            }
        } footer: {
            if blocked {
                Text("Remove the backup model first")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.removeBackupFirst)
            }
        }
        .listRowBackground(Theme.surface)
    }

    // MARK: - Parts

    private func problemLabel(_ text: Text, identifier: String) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondaryText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var alertTitle: Text {
        switch models.alert {
        case .keyNotSaved: Text("The key could not be saved.")
        case .keyNotRemoved: Text("The key could not be removed.")
        case .saveFailed, nil: Text("The change could not be saved.")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding {
            models.alert != nil
        } set: { presented in
            if !presented {
                models.alert = nil
            }
        }
    }
}

/// The models a service listed (decision 14): sorted, searchable; picking
/// one fills the model field.
struct ModelListSheet: View {
    @Environment(ModelSettingsModel.self) private var models
    @State private var search = ""

    private var shown: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? models.listedModels : models.listedModels.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(shown, id: \.self) { name in
                Button {
                    models.pickModel(name)
                } label: {
                    Text(verbatim: name)
                        .foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier(AccessibilityID.modelListRow(name))
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        models.isShowingModelList = false
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.modelListCancelButton)
                }
            }
        }
    }
}

extension View {
    /// A text field drawn 22 pt tall in its row whose 44 pt around it
    /// focuses it too, so its tap target is at least 44 pt (ux section 6).
    func tappableField(_ focus: @escaping () -> Void) -> some View {
        frame(minHeight: Theme.minimumTapTarget)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: focus)
            }
    }
}
