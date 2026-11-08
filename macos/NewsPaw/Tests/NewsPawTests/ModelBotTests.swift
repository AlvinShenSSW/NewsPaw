import Foundation
import Testing
@testable import NewsPaw

@Test func editingOneModelPreservesSiblingSlotsAndKeychainReferences() throws {
    let ids = ["normal_primary", "normal_backup", "adult_primary", "adult_backup"]
    let rows = ids.enumerated().map { index, id in
        ["id": id, "model": "model-\(index)", "credential_ref": "fixture-keychain-\(index)"]
    }
    let original: [String: Any] = ["model_profiles": rows, "future_field": 4]
    let changed = try ProtectedSettings.modify(original, collection: "model_profiles", id: "adult_backup", fields: ["model": "next-model"])
    let result = try #require(changed["model_profiles"] as? [[String: String]])
    #expect(result.prefix(3).elementsEqual(rows.prefix(3)))
    #expect(result[3]["credential_ref"] == "fixture-keychain-3")
    #expect(result[3]["model"] == "next-model")
    #expect(changed["future_field"] as? Int == 4)
}

@Test func displayedBotStateIncludesExactGenerationAndReadOnlyVerification() throws {
    let fixture = Data("""
    {"id":"bot2","name":"Fixture","verified":true,"paired":false,"paused":false,"generation":9,"status":"verified","username":"fixture"}
    """.utf8)
    let status: BotStatus = try BackendRPC.decode(fixture)
    #expect(status.generation == 9)
    #expect(status.label == .unpaired)
    #expect(!status.paired)
    #expect(ConnectionCopy.verify.text(.ja) != ConnectionCopy.test.text(.ja))
}

@Test func modelVerificationRetryKeepsItsOriginalRequest() {
    let request = ModelProbeRequest(revision: 7, capability: "vision", units: 25)
    let original = request.fields(profileId: "normal_primary")
    let retry = request.fields(profileId: "normal_primary")
    #expect(retry["probe_id"] as? String == original["probe_id"] as? String)
    #expect(retry["revision"] as? Int == 7)
    #expect(retry["capability"] as? String == "vision")
    #expect(retry["hold_units"] as? Int == 25)
}
