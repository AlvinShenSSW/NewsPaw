import XCTest

/// RD21 criteria 11 and 12: every Settings row of ux S8 present at this
/// issue opens a screen with its title, and About's three licences open
/// their full texts. Rows of later issues (Usage, RD17; Data's import and
/// export rows, RD08 and RD20) are not there yet.
final class SettingsRowTests: ReadingTestCase {
    func testEveryRowOpensItsScreen() {
        launchReading()
        let rows = [
            (AccessibilityID.modelsRow, "Models & Translation"),
            (AccessibilityID.refreshRow, "Refresh"),
            (AccessibilityID.readingSettingsRow, "Reading"),
            (AccessibilityID.adultPartitionRow, "Adult Partition"),
            (AccessibilityID.dataRow, "Data"),
            (AccessibilityID.aboutRow, "About"),
        ]
        for (row, title) in rows {
            openSettings(row: row)
            waitFor(app.navigationBars[title])
        }
        XCTAssertFalse(waitFor(element(AccessibilityID.versionValue)).label.isEmpty)

        let licences = [
            ("grdb.swift", "GRDB.swift", "MIT License", "Gwendal Roué"),
            ("swiftsoup", "SwiftSoup", "MIT License", "Jonathan Hedley"),
            ("readability", "Readability", "Apache License 2.0", "Arc90"),
        ]
        for (id, name, licence, holder) in licences {
            let row = scrollTo(element(AccessibilityID.licenceRow(id)))
            XCTAssertTrue(row.label.contains(name) && row.label.contains(licence), row.label)
            row.tap()
            waitFor(app.navigationBars[name])
            let text = waitFor(element(AccessibilityID.licenceText))
            XCTAssertTrue(text.label.contains("Copyright"), "\(id): \(text.label.prefix(80))")
            XCTAssertTrue(text.label.contains(holder), "\(id)")
            XCTAssertTrue(element(AccessibilityID.licenceAddress).label.hasPrefix("https://github.com/"))
            if id == "readability" {
                XCTAssertTrue(text.label.contains("Version 2.0, January 2004"))
                XCTAssertTrue(text.label.contains("END OF TERMS AND CONDITIONS"))
            } else {
                XCTAssertTrue(text.label.contains("Permission is hereby granted"))
            }
            goBack()
            waitFor(app.navigationBars["About"])
        }
    }
}
