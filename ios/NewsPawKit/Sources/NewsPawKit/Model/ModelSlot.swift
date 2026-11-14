import Foundation
import GRDB

/// Which of a library's two model slots (spec N08): the primary, and an
/// optional backup. The raw values are stored in `model_slot.role`.
///
/// Adding a case needs a schema migration, even an empty one, so that an
/// older build refuses the database instead of failing to read the row.
public enum ModelRole: String, Sendable, Hashable, CaseIterable, Codable {
    case primary
    case backup
}

/// A service preset (spec N08; RD13 decision 6). A preset only fills in the
/// address; the raw values are stored in `model_slot.preset`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum ModelPreset: String, Sendable, Hashable, CaseIterable, Codable {
    case openAI = "openai"
    case deepSeek = "deepseek"
    case xAI = "xai"
    case miMo = "mimo"
    case openRouter = "openrouter"
    case gemini
    case custom

    /// The address the preset fills in: the service's OpenAI-compatible
    /// base address, in normal form. Empty for Custom.
    ///
    /// MiMo's is the Token Plan address of the China region, by the owner's
    /// instruction of 2026-11-14 (decision 6).
    public var address: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .xAI: "https://api.x.ai/v1"
        case .miMo: "https://token-plan-cn.xiaomimimo.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: ""
        }
    }
}

/// What a model request was for (spec N11). Stored in `usage.purpose`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum UsagePurpose: String, Sendable, Hashable, CaseIterable, Codable {
    case titles
    case body
    case page
    case overview
    case test
}

/// How a sent model request ended (spec N11; RD13 decision 10). Stored in
/// `usage.outcome`.
///
/// Adding a case needs a schema migration, even an empty one.
public enum UsageOutcome: String, Sendable, Hashable, CaseIterable, Codable {
    case ok
    case refused
    case cutOff = "cut_off"
    case malformed
    case keyRejected = "key_rejected"
    case modelNotFound = "model_not_found"
    case badRequest = "bad_request"
    case limited
    case serverError = "server_error"
    case unreachable
    case cancelled
}

/// The result line of "Test" (ux S9; RD13 decisions 9 and 10). Stored in
/// `model_slot.test_outcome`; no value there is "Not tested".
///
/// Adding a case needs a schema migration, even an empty one.
public enum TestOutcome: String, Sendable, Hashable, CaseIterable, Codable {
    case passed
    case keyRejected = "key_rejected"
    case modelNotFound = "model_not_found"
    case limited
    case couldNotConnect = "could_not_connect"
}

/// One stored model slot of a library (spec section 4). It holds the
/// keychain reference of its key, never the key.
public struct ModelSlot: Sendable, Hashable {
    public let role: ModelRole
    public let preset: ModelPreset
    /// The service address in normal form (`ModelAddress.normalise`).
    public let baseURL: String
    public let model: String
    /// The keychain reference of the key, or `nil` when the slot has none.
    let keyRef: String?
    /// The last Test result kept with the slot, or `nil` for "Not tested".
    public let testOutcome: TestOutcome?
    public let updatedAt: Date

    init(role: ModelRole, preset: ModelPreset, baseURL: String, model: String, keyRef: String?, testOutcome: TestOutcome?, updatedAt: Date) {
        self.role = role
        self.preset = preset
        self.baseURL = baseURL
        self.model = model
        self.keyRef = keyRef
        self.testOutcome = testOutcome
        self.updatedAt = updatedAt
    }
}

extension ModelSlot: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "model_slot"

    enum CodingKeys: String, CodingKey {
        case role
        case preset
        case baseURL = "base_url"
        case model
        case keyRef = "key_ref"
        case testOutcome = "test_outcome"
        case updatedAt = "updated_at"
    }
}

/// One `usage` row (spec N11): a model request that was sent.
struct UsageRecord: Sendable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usage"

    let id: UUID
    /// The model name as sent.
    let model: String
    let purpose: UsagePurpose
    let inputTokens: Int?
    let outputTokens: Int?
    let outcome: UsageOutcome
    let at: Date

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case purpose
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case outcome
        case at
    }

    static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy {
        .lowercaseString
    }
}
