import Foundation

/// Why a slot could not be saved, removed or used for Test or Load List.
public enum ModelSettingsError: Error, Sendable, Hashable {
    case invalidAddress(ModelAddressProblem)
    case invalidModelName(ModelNameProblem)
    /// A backup is set up only while a primary exists.
    case primaryNeeded
    /// The primary is not removed while a backup exists.
    case backupExists
    /// The keychain did not take the new key; nothing was written.
    case keyNotSaved
    /// The keychain did not remove the key; the row is unchanged.
    case keyNotRemoved
}

/// Whether a saved slot has a usable key (decision 3).
public enum StoredKeyState: Sendable, Hashable {
    /// "Key needed": no reference, or no item for it.
    case missing
    /// The key, shown as dots and its last four characters (`nil` when it
    /// is shorter than 12 characters and only the dots are shown).
    case present(lastFour: String?)
}

/// A saved slot and the state of its key.
public struct ModelSlotStatus: Sendable, Hashable {
    public let slot: ModelSlot
    public let key: StoredKeyState
}

/// What the slot form shows: Save writes it, Test and Load List act on it
/// without saving (decision 9).
public struct ModelSlotDraft: Sendable {
    public var role: ModelRole
    public var preset: ModelPreset
    public var address: String
    public var model: String
    /// A key typed into the form, or `nil` to keep the stored one (usable
    /// only while the address keeps the saved address's origin).
    public var newKey: SecretKey?

    public init(role: ModelRole, preset: ModelPreset, address: String, model: String, newKey: SecretKey?) {
        self.role = role
        self.preset = preset
        self.address = address
        self.model = model
        self.newKey = newKey
    }
}

/// The model slots, keys and model requests of one library (spec N08, N11,
/// section 6; RD13 decision 12): the only way to read slots, save them,
/// test, list and send. It is made from one library, one key store of the
/// same partition and one HTTP stand-in, and has no parameter that names
/// another library's slot. There is no default slot: with no row for the
/// asked role it fails with "no model set up".
public final class LibraryModels: Sendable {
    private let library: Library
    private let keys: any KeyStore
    private let http: any ModelHTTP

    /// The instruction of Test's request (decision 9).
    static let testInstructions = "Repeat the text."
    /// The texts of Test's request.
    static let testTexts = ["Hello"]

    public init(library: Library, keys: any KeyStore, http: any ModelHTTP) {
        precondition(keys.partition == library.partition, "a key store of another partition")
        self.library = library
        self.keys = keys
        self.http = http
    }

    public var partition: Partition {
        library.partition
    }

    // MARK: - Reading

    /// The saved slots with the state of their keys.
    public func statuses() async throws -> [ModelRole: ModelSlotStatus] {
        let slots = try await library.modelSlots()
        return slots.mapValues { slot in
            let key: StoredKeyState = if let stored = storedKey(of: slot) {
                .present(lastFour: stored.lastFour)
            } else {
                .missing
            }
            return ModelSlotStatus(slot: slot, key: key)
        }
    }

    /// The slot's key, or `nil` when it has no reference, no item for it, or
    /// the keychain cannot be read.
    private func storedKey(of slot: ModelSlot) -> SecretKey? {
        guard let reference = slot.keyRef else { return nil }
        return (try? keys.read(reference)) ?? nil
    }

    // MARK: - Saving and removing

    /// Saves the form (decisions 3 and 9). Saving never sends a request.
    ///
    /// With a new key: the key is added under a new reference, then the row
    /// written, then the old reference's item removed; if the row cannot be
    /// written the new item is removed and the old slot is unchanged.
    /// Without one, the stored key is kept only while the address keeps its
    /// origin; otherwise its item is removed and the row has no reference.
    ///
    /// - Parameter testedOutcome: the result of a Test of exactly these
    ///   address, model and key, made since the form last changed; it is kept
    ///   with the slot. Without it, a change of address, model or key sets
    ///   the slot back to "Not tested".
    /// - Throws: `ModelSettingsError`, or a `LibraryError` when the row
    ///   cannot be written.
    @discardableResult
    public func save(_ draft: ModelSlotDraft, testedOutcome: TestOutcome?) async throws -> ModelSlotStatus {
        let address = try Self.address(draft.address)
        let model = try Self.modelName(draft.model)
        let existing = try await library.modelSlot(draft.role)
        if draft.role == .backup, try await library.modelSlot(.primary) == nil {
            throw ModelSettingsError.primaryNeeded
        }
        var newReference: String?
        if let key = draft.newKey {
            do {
                newReference = try keys.add(key)
            } catch {
                throw ModelSettingsError.keyNotSaved
            }
        }
        let keptReference: String? = if newReference == nil, let existing, ModelAddress.sameOrigin(existing.baseURL, address) {
            existing.keyRef
        } else {
            nil
        }
        let reference = newReference ?? keptReference
        let unchanged = existing.map { existing in
            existing.baseURL == address && existing.model == model && newReference == nil && keptReference != nil
        } ?? false
        let slot = ModelSlot(
            role: draft.role, preset: draft.preset, baseURL: address, model: model, keyRef: reference,
            testOutcome: testedOutcome ?? (unchanged ? existing?.testOutcome : nil), updatedAt: library.now()
        )
        do {
            try await library.saveModelSlot(slot)
        } catch {
            if let newReference {
                try? keys.remove(newReference)
            }
            throw error
        }
        // A failure here leaves an item no row names: invisible, never sent.
        if let old = existing?.keyRef, old != reference {
            try? keys.remove(old)
        }
        let key: StoredKeyState = if let stored = storedKey(of: slot) { .present(lastFour: stored.lastFour) } else { .missing }
        return ModelSlotStatus(slot: slot, key: key)
    }

    /// Removes a slot's key: the keychain item first, then the reference.
    /// The slot stays, at "Key needed".
    ///
    /// - Throws: `ModelSettingsError.keyNotRemoved`; the row is then
    ///   unchanged.
    public func removeKey(_ role: ModelRole) async throws {
        guard let slot = try await library.modelSlot(role), let reference = slot.keyRef else { return }
        do {
            try keys.remove(reference)
        } catch {
            throw ModelSettingsError.keyNotRemoved
        }
        try await library.clearModelKey(role, keyRef: reference)
    }

    /// Removes a slot: its key's item first, then the row. The primary is
    /// not removed while a backup exists.
    ///
    /// - Throws: `ModelSettingsError.backupExists`,
    ///   `ModelSettingsError.keyNotRemoved` (the row then stays).
    public func removeSlot(_ role: ModelRole) async throws {
        guard let slot = try await library.modelSlot(role) else { return }
        if role == .primary, try await library.modelSlot(.backup) != nil {
            throw ModelSettingsError.backupExists
        }
        if let reference = slot.keyRef {
            do {
                try keys.remove(reference)
            } catch {
                throw ModelSettingsError.keyNotRemoved
            }
        }
        try await library.deleteModelSlot(role)
    }

    // MARK: - Test and Load List

    /// Sends Test's request for what the form shows, without saving
    /// (decision 9), and writes its usage row. The result is kept with the
    /// slot at once when the tested address, model and key are the saved
    /// ones.
    ///
    /// - Throws: `ModelFailure.keyNeeded` (no request is made),
    ///   `ModelSettingsError` for an address or name that is refused, or
    ///   `CancellationError` (the usage row is written, no result kept).
    public func test(_ draft: ModelSlotDraft) async throws -> TestOutcome {
        let address = try Self.address(draft.address)
        let model = try Self.modelName(draft.model)
        let existing = try await library.modelSlot(draft.role)
        guard let key = usableKey(draft, existing: existing, address: address) else {
            throw ModelFailure.keyNeeded
        }
        let exchange = try await chat(
            address: address, model: model, instructions: Self.testInstructions, texts: Self.testTexts, key: key, purpose: .test
        )
        // A completion with a message passes; its content is not judged.
        let outcome: TestOutcome = switch exchange {
        case .completion: .passed
        case .failed(let failure): TestOutcome(failure)
        }
        try Task.checkCancellation()
        if draft.newKey == nil, let existing, let reference = existing.keyRef, existing.baseURL == address, existing.model == model {
            try? await library.setModelTestOutcome(outcome, role: draft.role, baseURL: address, model: model, keyRef: reference)
        }
        return outcome
    }

    /// The identifiers the service at the form's address lists, sorted, at
    /// most 1,000. Writes no usage row: a list names no model and has no
    /// purpose (decision 11).
    ///
    /// - Throws: `ModelFailure` (`keyNeeded` without a request),
    ///   `ModelSettingsError.invalidAddress`, or `CancellationError`.
    public func listModels(_ draft: ModelSlotDraft) async throws -> [String] {
        let address = try Self.address(draft.address)
        let existing = try await library.modelSlot(draft.role)
        guard let key = usableKey(draft, existing: existing, address: address) else {
            throw ModelFailure.keyNeeded
        }
        guard let request = ChatWire.listRequest(address: address, key: key) else {
            throw ModelFailure.unreachable
        }
        let response: ModelHTTPResponse
        do {
            response = try await http.send(request)
        } catch let failure as ModelHTTPFailure {
            throw ChatWire.failure(failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ModelFailure.unreachable
        }
        switch ChatWire.classifyList(response) {
        case .success(let models): return models
        case .failure(let failure): throw failure
        }
    }

    /// The typed key, or the stored one when no key was typed and the
    /// form's address keeps the saved address's origin (decision 3).
    private func usableKey(_ draft: ModelSlotDraft, existing: ModelSlot?, address: String) -> SecretKey? {
        if let key = draft.newKey {
            return key
        }
        guard let existing, ModelAddress.sameOrigin(existing.baseURL, address) else { return nil }
        return storedKey(of: existing)
    }

    // MARK: - Sending

    /// Sends `texts` to the slot of `role` and returns the reply's texts
    /// (decision 8). The system message is `instructions` followed by the
    /// sentence that fixes the reply's shape; how many texts to return, and
    /// in what order, is for `instructions` to say. Every sent request
    /// writes one usage row.
    ///
    /// - Throws: a `ModelFailure` (`noModelSetUp` and `keyNeeded` without a
    ///   request or a row), or `CancellationError`.
    public func send(texts: [String], instructions: String, purpose: UsagePurpose, role: ModelRole) async throws -> ModelReply {
        guard let slot = try await library.modelSlot(role) else {
            throw ModelFailure.noModelSetUp
        }
        // Checked again when sending (decision 5): a stored address this
        // build refuses is never requested.
        guard case .success(let address) = ModelAddress.normalise(slot.baseURL, allowsLoopbackHTTP: ModelAddress.allowsLoopbackHTTPInThisBuild),
              case .success(let model) = ModelName.validate(slot.model)
        else {
            throw ModelFailure.unreachable
        }
        guard let key = storedKey(of: slot) else {
            throw ModelFailure.keyNeeded
        }
        switch try await chat(address: address, model: model, instructions: instructions, texts: texts, key: key, purpose: purpose) {
        case .completion(.success(let reply)): return reply
        case .completion(.failure(let failure)), .failed(let failure): throw failure
        }
    }

    /// How one chat exchange ended.
    private enum ChatExchange {
        /// The service answered 200 with a chat completion, read as the
        /// reply or as refused, cut off or malformed.
        case completion(Result<ModelReply, ModelFailure>)
        /// Any other answer, or none.
        case failed(ModelFailure)
    }

    /// Sends one chat request, writes its usage row and returns how it
    /// ended. A cancelled request writes its row and throws.
    private func chat(
        address: String, model: String, instructions: String, texts: [String], key: SecretKey, purpose: UsagePurpose
    ) async throws -> ChatExchange {
        guard let request = ChatWire.chatRequest(address: address, model: model, instructions: instructions, texts: texts, key: key) else {
            throw ModelFailure.unreachable
        }
        let classified: Result<ChatWire.Completion, ModelFailure>
        do {
            classified = ChatWire.classifyChat(try await http.send(request))
        } catch let failure as ModelHTTPFailure {
            classified = .failure(ChatWire.failure(failure))
        } catch is CancellationError {
            await record(model: model, purpose: purpose, outcome: .cancelled)
            throw CancellationError()
        } catch {
            classified = .failure(.unreachable)
        }
        switch classified {
        case .success(let completion):
            let interpreted = ChatWire.interpret(completion)
            let outcome: UsageOutcome = switch interpreted {
            case .success: .ok
            case .failure(let failure): failure.usageOutcome ?? .malformed
            }
            await record(
                model: model, purpose: purpose, inputTokens: completion.promptTokens, outputTokens: completion.completionTokens,
                outcome: outcome
            )
            return .completion(interpreted)
        case .failure(let failure):
            await record(model: model, purpose: purpose, outcome: failure.usageOutcome ?? .unreachable)
            return .failed(failure)
        }
    }

    /// Writes one usage row from a new unstructured task whose value is
    /// awaited: the database's asynchronous write refuses to start in a
    /// cancelled task, and the row of a cancelled request would otherwise be
    /// lost. A failure to write is ignored (decision 11).
    private func record(model: String, purpose: UsagePurpose, inputTokens: Int? = nil, outputTokens: Int? = nil, outcome: UsageOutcome) async {
        let library = library
        let row = UsageRecord(
            id: UUID(), model: model, purpose: purpose, inputTokens: inputTokens, outputTokens: outputTokens, outcome: outcome,
            at: library.now()
        )
        await Task {
            try? await library.insertUsage(row)
        }.value
    }

    // MARK: - Rules

    private static func address(_ text: String) throws -> String {
        switch ModelAddress.normalise(text, allowsLoopbackHTTP: ModelAddress.allowsLoopbackHTTPInThisBuild) {
        case .success(let address): address
        case .failure(let problem): throw ModelSettingsError.invalidAddress(problem)
        }
    }

    private static func modelName(_ text: String) throws -> String {
        switch ModelName.validate(text) {
        case .success(let name): name
        case .failure(let problem): throw ModelSettingsError.invalidModelName(problem)
        }
    }
}
