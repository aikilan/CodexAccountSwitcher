import SwiftUI
import XCTest
@testable import Orbit

final class AppAppearancePreferenceTests: XCTestCase {
    func testResolvedFallsBackToSystemForUnknownValue() {
        XCTAssertEqual(AppAppearancePreference.resolved(from: "unknown"), .system)
    }

    func testColorSchemeMappingMatchesPreference() {
        XCTAssertNil(AppAppearancePreference.system.colorScheme)
        XCTAssertEqual(AppAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppAppearancePreference.dark.colorScheme, .dark)
    }

    func testEnglishTitlesAreLocalized() {
        let originalPreference = L10n.currentLanguagePreference
        defer {
            L10n.setLanguagePreference(originalPreference)
        }

        L10n.setLanguagePreference(.english)

        XCTAssertEqual(AppAppearancePreference.system.title, "Follow System")
        XCTAssertEqual(AppAppearancePreference.light.title, "Light")
        XCTAssertEqual(AppAppearancePreference.dark.title, "Dark")
    }
}
