import CoreFoundation
import Foundation

/// Words the X and Settings views still use; they move into `L10n` when those pages are
/// redesigned (R11, R12).
enum ConnectionCopy {
    case policy, schedule, allowAdult, save, vision, speech, settled, reserved, remaining

    func text(_ locale: AppLanguage) -> String {
        let values: (String, String, String) = switch self {
        case .save: ("保存", "Save", "保存")
        case .vision: ("视觉理解", "Vision", "画像認識")
        case .speech: ("语音转写", "Transcription", "音声の文字起こし")
        case .allowAdult: ("允许成人分区投递", "Allow adult deliveries", "成人向け配信を許可")
        case .policy: ("运行策略", "Run policy", "実行ポリシー")
        case .settled: ("已结算", "Settled", "精算済み")
        case .reserved: ("预留", "Held", "予約済み")
        case .remaining: ("剩余", "Remaining", "残り")
        case .schedule: ("定时推送", "Scheduled delivery", "定時配信")
        }
        return switch locale {
        case .zhHans: values.0
        case .en: values.1
        case .ja: values.2
        }
    }
}

struct SettingsRevision: Decodable { let revision: Int }

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

func boundedUnits(_ raw: String) -> Int? {
    guard let number = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          (0...9_007_199_254_740_992).contains(number) else { return nil }
    return number
}
