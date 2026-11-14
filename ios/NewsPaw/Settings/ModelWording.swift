import NewsPawKit
import SwiftUI

/// The wording of the model screens (ux S8, S9, section 4; RD13 decision
/// 15). No internal word (slot, partition, reference) is shown.
enum ModelWording {
    /// A preset's name. Service names are not translated.
    static func preset(_ preset: ModelPreset) -> Text {
        switch preset {
        case .openAI: Text(verbatim: "OpenAI")
        case .deepSeek: Text(verbatim: "DeepSeek")
        case .xAI: Text(verbatim: "xAI")
        case .miMo: Text(verbatim: "MiMo")
        case .openRouter: Text(verbatim: "OpenRouter")
        case .gemini: Text("Gemini (Compatible)")
        case .custom: Text("Custom")
        }
    }

    static func role(_ role: ModelRole) -> Text {
        switch role {
        case .primary: Text("Primary Model")
        case .backup: Text("Backup Model")
        }
    }

    /// ux S9's five Test lines, and "Not tested".
    static func testLine(_ outcome: TestOutcome?) -> Text {
        switch outcome {
        case .passed: Text("Passed")
        case .keyRejected: Text("Key rejected")
        case .modelNotFound: Text("Model not found")
        case .limited: Text("Quota or rate limit")
        case .couldNotConnect: Text("Could not connect")
        case nil: Text("Not tested")
        }
    }

    /// The sentence under a failed line: ux section 4's where it has one,
    /// and RD13's own for a missing model.
    static func sentence(_ outcome: TestOutcome) -> Text? {
        switch outcome {
        case .passed: nil
        case .keyRejected: Text("The service rejected the key")
        case .modelNotFound: Text("The service does not have this model")
        case .limited: Text("The service is limiting requests. Try again later")
        case .couldNotConnect: Text("Could not reach the service")
        }
    }

    /// The state a Models & Translation row shows.
    static func state(_ status: ModelSlotStatus) -> Text {
        if status.key == .missing {
            return Text("Key needed")
        }
        return testLine(status.slot.testOutcome)
    }

    static func addressProblem(_ problem: ModelAddressProblem) -> Text? {
        switch problem {
        case .empty: nil
        case .tooLong: Text("Use at most \(ModelAddress.maximumLength) characters.")
        case .invalid, .noHost: Text("This is not a valid address.")
        case .notHTTPS: Text("The address must start with https://.")
        case .credentials: Text("The address cannot contain a user name or password.")
        case .queryOrFragment: Text("The address cannot contain “?” or “#”.")
        }
    }

    static func modelProblem(_ problem: ModelNameProblem) -> Text? {
        switch problem {
        case .empty: nil
        case .tooLong: Text("Use at most \(ModelName.maximumLength) characters.")
        case .controlCharacter: Text("The model name cannot contain line breaks or control characters.")
        }
    }

    static func keyProblem(_ problem: KeyProblem) -> Text? {
        switch problem {
        case .empty: nil
        case .tooLong: Text("Use at most \(SecretKey.maximumLength) characters.")
        case .invalidCharacter: Text("A key can contain only English letters, digits and symbols, on one line.")
        }
    }
}
