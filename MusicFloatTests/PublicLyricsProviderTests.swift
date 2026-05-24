import XCTest
@testable import MusicFloat

@MainActor
final class PublicLyricsProviderTests: XCTestCase {
    func testAppleScriptMusicAppLyricsWinBeforeOtherProviders() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: document(source: .musicApp, text: "Library lyrics"),
            mediaUserTokenConfigured: true,
            appleMusicWeb: document(source: .appleMusicWeb, text: "Web lyrics", timed: true),
            lrclib: document(source: .lrclib, text: "LRCLIB lyrics", timed: true),
            hasAccessibilityPermission: true,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let result = await provider.lyrics(for: track())

        XCTAssertEqual(result, .available(document(source: .musicApp, text: "Library lyrics")))
        XCTAssertEqual(calls.values, ["appleScript"])
    }

    func testAccessibilityDeniedStillAllowsAppleMusicWebWhenConfigured() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: true,
            mediaUserTokenConfigured: true,
            appleMusicWeb: document(source: .appleMusicWeb, text: "Web lyrics", timed: true),
            lrclib: document(source: .lrclib, text: "LRCLIB lyrics", timed: true),
            hasAccessibilityPermission: false,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let result = await provider.lyrics(for: track())

        XCTAssertEqual(result, .available(document(source: .appleMusicWeb, text: "Web lyrics", timed: true)))
        XCTAssertEqual(calls.values, ["appleScript", "requiresAX", "mediaToken", "appleMusicWeb"])
    }

    func testAccessibilityDeniedStillAllowsLRCLIBWhenFallbackEnabled() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: true,
            mediaUserTokenConfigured: false,
            appleMusicWeb: document(source: .appleMusicWeb, text: "Web lyrics", timed: true),
            lrclib: document(source: .lrclib, text: "LRCLIB lyrics", timed: true),
            hasAccessibilityPermission: false,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let result = await provider.lyrics(for: track())

        XCTAssertEqual(result, .available(document(source: .lrclib, text: "LRCLIB lyrics", timed: true)))
        XCTAssertEqual(calls.values, ["appleScript", "requiresAX", "mediaToken", "lrclib"])
    }

    func testProviderOrderFallsThroughAppleScriptWebLRCLIBThenAX() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            lrclib: nil,
            hasAccessibilityPermission: true,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let result = await provider.lyrics(for: track())

        XCTAssertEqual(result, .available(document(source: .musicAppUI, text: "AX lyrics")))
        XCTAssertEqual(calls.values, [
            "appleScript",
            "requiresAX",
            "mediaToken",
            "appleMusicWeb",
            "lrclib",
            "hasAX",
            "ax"
        ])
    }

    func testAccessibilityMessageOnlyAfterNonAXProvidersMiss() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: true,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            lrclib: nil,
            hasAccessibilityPermission: false,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let result = await provider.lyrics(for: track())

        XCTAssertEqual(
            result,
            .failed("Allow MusicFloat in Privacy & Security > Accessibility to use Music lyrics.")
        )
        XCTAssertEqual(calls.values, [
            "appleScript",
            "requiresAX",
            "mediaToken",
            "appleMusicWeb",
            "lrclib",
            "hasAX"
        ])
    }

    private func dependencies(
        calls: CallLog,
        appleScript: LyricsDocument?,
        requiresAccessibilityPermission: Bool = false,
        mediaUserTokenConfigured: Bool,
        appleMusicWeb: LyricsDocument?,
        lrclib: LyricsDocument?,
        hasAccessibilityPermission: Bool,
        ax: LyricsDocument?
    ) -> PublicLyricsProvider.Dependencies {
        PublicLyricsProvider.Dependencies(
            fetchAppleScriptLyrics: {
                calls.append("appleScript")
                return appleScript
            },
            requiresAccessibilityPermission: {
                calls.append("requiresAX")
                return requiresAccessibilityPermission
            },
            hasAccessibilityPermission: {
                calls.append("hasAX")
                return hasAccessibilityPermission
            },
            shouldRetryVisibleLyrics: {
                calls.append("retryAX")
                return false
            },
            isMediaUserTokenConfigured: {
                calls.append("mediaToken")
                return mediaUserTokenConfigured
            },
            fetchAppleMusicWebLyrics: { _ in
                calls.append("appleMusicWeb")
                return appleMusicWeb
            },
            isLRCLIBFallbackEnabled: {
                true
            },
            fetchLRCLIBLyrics: { _ in
                calls.append("lrclib")
                return lrclib
            },
            fetchAXLyrics: {
                calls.append("ax")
                return ax
            },
            sleep: { _ in
                calls.append("sleep")
            }
        )
    }

    private final class CallLog {
        private(set) var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }
    }

    private func track(id: String = "track-1") -> NowPlayingTrack {
        NowPlayingTrack(
            id: id,
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Music"
        )
    }

    private func document(
        source: LyricsSource,
        text: String,
        timed: Bool = false
    ) -> LyricsDocument {
        LyricsDocument(
            source: source,
            lines: [LyricLine(id: 0, text: text, startTime: timed ? 1 : nil)],
            isTimed: timed
        )
    }
}
