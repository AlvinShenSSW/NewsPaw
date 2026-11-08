import Foundation
import Testing

@testable import NewsPaw

@Test func xAccountOverridesPreserveInheritanceAndExplicitEmpty() {
    let inherited = XRouteInput.overrides(times: nil, bots: nil, style: "")
    #expect(inherited["times"] is NSNull)
    #expect(inherited["bot_ids"] is NSNull)
    #expect(inherited["style"] is NSNull)
    let explicit = XRouteInput.overrides(times: "20:30, 07:00", bots: [], style: "text")
    #expect(explicit["times"] as? [String] == ["07:00", "20:30"])
    #expect(explicit["bot_ids"] as? [String] == [])
    #expect(explicit["style"] as? String == "text")
    #expect(XRouteInput.overrides(times: "", bots: nil, style: "")["times"] as? [String] == [])
}

@Test func xCoverageDistinguishesPartialFromHistoricalComplete() throws {
    let data = Data(#"""
        {"state":"incomplete","reason":"page_limit","latest":{
          "state":"incomplete","reason":"page_limit","completed_pages":1,
          "historical":false,"through_time":"2026-11-08T02:00:00+00:00"},
         "last_complete":{"state":"complete","completed_pages":1,"historical":false,
           "from_time":"2026-11-07T01:59:00+00:00","through_time":"2026-11-08T01:59:00+00:00"}}
        """#.utf8)
    let view: XCoverage = try BackendRPC.decode(data)
    #expect(view.latest?.fromTime == nil)
    #expect(view.lastComplete?.throughTime != view.latest?.throughTime)
    for copy in XCopy.allCases {
        #expect(AppLanguage.allCases.allSatisfy { !copy.text($0).isEmpty })
    }
}

@Test func xAccountRetainsStableRemoteIdentityAcrossHandleChanges() throws {
    func account(_ handle: String, remote: String) throws -> XAccount {
        let data = Data(#"{"id":"local","handle":"\#(handle)","priority":"normal","state":"ready","remote_id":\#(remote),"can_collect":true,"member_active":false}"#.utf8)
        return try BackendRPC.decode(data)
    }
    let first = try account("original", remote: #""9876543210123456789""#)
    let renamed = try account("renamed", remote: #""9876543210123456789""#)
    #expect(first.handle != renamed.handle)
    #expect(first.remoteId == "9876543210123456789")
    #expect(first.remoteId == renamed.remoteId)
    #expect(try account("draft", remote: "null").remoteId == nil)
}

@Test func xPaginationGapHasSpecificCopyInEachLanguage() {
    for locale in AppLanguage.allCases {
        #expect(xState("pagination_gap", locale) != xState("unknown", locale))
        #expect(xState("pagination_gap", locale) != xState("partial", locale))
    }
}
