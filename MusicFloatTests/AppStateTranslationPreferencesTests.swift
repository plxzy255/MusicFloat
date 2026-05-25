import XCTest
@testable import MusicFloat

@MainActor
final class AppStateTranslationPreferencesTests: XCTestCase {
    func testSystemLanguageDefaultIsStoredAsStableIdentifier() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.systemLanguageDefault.\(UUID().uuidString)")!

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.preferredTranslationLanguageIdentifier, AppState.systemLanguageIdentifier)
        XCTAssertEqual(
            defaults.string(forKey: "preferredTranslationLanguageIdentifier"),
            AppState.systemLanguageIdentifier
        )
    }

    func testInvalidStoredTargetLanguageFallsBackToSystemLanguage() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.invalidLanguage.\(UUID().uuidString)")!
        defaults.set("French", forKey: "preferredTranslationLanguageIdentifier")

        let appState = AppState(userDefaults: defaults)

        XCTAssertEqual(appState.preferredTranslationLanguageIdentifier, AppState.systemLanguageIdentifier)
        XCTAssertEqual(
            defaults.string(forKey: "preferredTranslationLanguageIdentifier"),
            AppState.systemLanguageIdentifier
        )
    }
}
