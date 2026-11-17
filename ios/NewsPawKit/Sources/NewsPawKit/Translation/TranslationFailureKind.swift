import Foundation

/// The three kinds of a model failure for translation (RD14 decision 6,
/// RD16 decision 12): what a translator does next depends on the kind.
enum TranslationFailureKind: Equatable {
    /// The model answered, but not with a usable translation: retried on
    /// the primary, never sent to the backup automatically.
    case content(TranslationFailure)
    /// The service did not answer usefully: once to a usable backup.
    case service(ModelFailure)
    /// The slot cannot be used until the owner changes it.
    case setUp(ModelFailure)

    init(_ failure: ModelFailure) {
        switch failure {
        case .refused: self = .content(.refused)
        case .cutOff: self = .content(.cutOff)
        case .malformed: self = .content(.malformed)
        case .badRequest: self = .content(.badRequest)
        case .limited, .serverError, .unreachable: self = .service(failure)
        case .noModelSetUp, .keyNeeded, .keyRejected, .modelNotFound: self = .setUp(failure)
        }
    }
}
