import Foundation
import Testing
@testable import NewsPaw

@Test func explicitEmptyAndInheritanceHaveSeparateWireRepresentations() throws {
    let category = AppConfig.Category(id: "japan", name: "Japan", partition: "normal")
    var draft = SubscriptionDraft(SubscriptionSelection(category: category, subscription: nil))
    #expect(draft.timezone == "Asia/Tokyo")
    #expect(draft.fields["source_mode"] as? String == "category")
    draft.inherited = false
    #expect(draft.fields["source_mode"] as? String == "explicit")
    #expect(draft.fields["source_ids"] as? [String] == [])
    draft.sourceIds = ["entertainment"]
    draft.weighted = true
    draft.domestic = 0
    draft.entertainment = 100
    #expect(draft.fields["source_ids"] as? [String] == ["entertainment"])
    #expect(draft.fields["focus_weights"] as? [String: Int] == ["domestic": 0, "entertainment": 100])
    draft.times = " 20:00,09:00,20:00 "
    #expect(draft.fields["times"] as? [String] == ["09:00", "20:00"])
}

@Test func newSourceIsInactiveAndUnclassifiedOnTheWire() throws {
    let source = SourceDraft(nil)
    let result = source.fields
    #expect(result["enabled"] as? Bool == false)
    #expect(result["kind"] as? String == "draft")
    #expect(result["partition"] is NSNull)
    #expect(result["category_ids"] as? [String] == [])
    #expect(result["focus"] == nil)
}

@Test func SourceAndSubscriptionActionsHaveDistinctThreeLanguageCopy() {
    for locale in AppLanguage.allCases {
        #expect(SubscriptionCopy.discover.text(locale) != SubscriptionCopy.trial.text(locale))
        #expect(SubscriptionCopy.previewPassed.text(locale) != SubscriptionCopy.enableSource.text(locale))
        #expect(SubscriptionCopy.inherit.text(locale) != SubscriptionCopy.explicit.text(locale))
    }
}
