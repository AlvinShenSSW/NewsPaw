import CoreFoundation
import Foundation

enum ProtectedSettings {
    static func record(_ data: Data, revision: Int, field: String = "document") throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actual = result["revision"] as? NSNumber,
              CFGetTypeID(actual) != CFBooleanGetTypeID(), actual.doubleValue == Double(actual.intValue),
              let document = result[field] as? [String: Any] else { throw BackendFailure.invalidReply }
        guard actual.intValue == revision else { throw BackendFailure.conflict }
        return document
    }

    static func modify(
        _ document: [String: Any], collection: String, id: String,
        fields: [String: Any], new: [String: Any]? = nil
    ) throws -> [String: Any] {
        var document = document
        guard var records = document[collection] as? [[String: Any]] else { throw BackendFailure.invalidReply }
        if let index = records.firstIndex(where: { $0["id"] as? String == id }) {
            records[index].merge(fields) { _, new in new }
        } else if var entry = new {
            entry.merge(fields) { _, new in new }
            records.append(entry)
        } else {
            throw BackendFailure.conflict
        }
        document[collection] = records
        return document
    }
}
