import XCTest
@testable import MusicFloat

@MainActor
final class AppleMusicCatalogResolverTests: XCTestCase {
    func testAppleScriptCatalogURLIsAcceptedWhenPersistentIDMatchesNotificationTrack() {
        let identity = AppleMusicCatalogResolver.identityFromAppleScript(
            raw: "https://music.apple.com/us/album/example/123456789?i=987654321||abc",
            expectedTrackID: "0000000000000ABC",
            lookupID: "test"
        )

        XCTAssertEqual(identity, AppleMusicCatalogResolver.Identity(storefront: "us", songID: "987654321"))
    }

    func testAppleScriptCatalogURLIsIgnoredWhenPersistentIDIsStale() {
        let identity = AppleMusicCatalogResolver.identityFromAppleScript(
            raw: "https://music.apple.com/us/album/old/111111111?i=222222222||0000000000000ABC",
            expectedTrackID: "0000000000000DEF",
            lookupID: "test"
        )

        XCTAssertNil(identity)
    }

    func testLegacyAppleScriptCatalogURLWithoutPersistentIDStillParses() {
        let identity = AppleMusicCatalogResolver.identityFromAppleScript(
            raw: "https://music.apple.com/fr/song/example/123456789",
            expectedTrackID: "track-fallback",
            lookupID: "test"
        )

        XCTAssertEqual(identity, AppleMusicCatalogResolver.Identity(storefront: "fr", songID: "123456789"))
    }
}
