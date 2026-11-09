import Foundation
import Testing
@testable import NewsPaw

@Test func SourceAndSubscriptionActionsHaveDistinctThreeLanguageCopy() {
    for locale in AppLanguage.allCases {
        #expect(SubscriptionCopy.discover.text(locale) != SubscriptionCopy.trial.text(locale))
        #expect(SubscriptionCopy.previewPassed.text(locale) != SubscriptionCopy.enableSource.text(locale))
        #expect(SubscriptionCopy.inherit.text(locale) != SubscriptionCopy.explicit.text(locale))
    }
}
