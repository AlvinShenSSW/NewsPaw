import GRDB

/// Why a library operation failed.
public enum LibraryError: Error, Sendable, Equatable {
    /// The database records a schema migration this build does not have: it
    /// was written by a newer version of the app. Nothing in it was changed.
    case newerSchema
    /// SQLite reports that the file is not a database or is corrupt.
    case damaged
    /// The library's file does not exist.
    case missing
    /// A source with the same address already exists in this library.
    case duplicateAddress
    /// A category name is empty once surrounding white space is removed.
    case emptyName
    /// A category name is longer than `Library.maximumCategoryNameLength`.
    case nameTooLong
    /// No category of this library has the given identifier.
    case unknownCategory
    /// A reordering is not a permutation of the library's categories.
    case invalidOrder
    /// The category chosen to receive the sources is the one being deleted or
    /// does not exist.
    case invalidMoveTarget
    /// Any other storage failure, with SQLite's own description.
    case storage(String)

    /// Maps an error thrown while opening or using a library. A
    /// `LibraryError` and a `CancellationError` pass through unchanged.
    static func wrapping(_ error: any Error) -> any Error {
        switch error {
        case is LibraryError, is CancellationError:
            return error
        case let error as DatabaseError:
            switch error.resultCode {
            case .SQLITE_NOTADB, .SQLITE_CORRUPT:
                return LibraryError.damaged
            default:
                return LibraryError.storage(error.description)
            }
        default:
            return LibraryError.storage(String(describing: error))
        }
    }
}
