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

    func testAvailableDocumentUsesMemoryCache() async {
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

        let first = await provider.lyrics(for: track())
        let second = await provider.lyrics(for: track())

        XCTAssertEqual(first, .available(document(source: .musicApp, text: "Library lyrics")))
        XCTAssertEqual(second, first)
        XCTAssertEqual(calls.values, ["appleScript"])
    }

    func testUnavailableResultIsNegativeCached() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: false,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            lrclib: nil,
            hasAccessibilityPermission: true,
            ax: nil
        ))

        let first = await provider.lyrics(for: track())
        let second = await provider.lyrics(for: track())

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(calls.values, [
            "appleScript",
            "requiresAX",
            "mediaToken",
            "appleMusicWeb",
            "lrclib",
            "hasAX",
            "ax",
            "retryAX"
        ])
    }

    func testProviderFailureUnavailableIsNotNegativeCached() async {
        let calls = CallLog()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: false,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            fetchAppleMusicWebLyrics: { _, _ in
                throw URLError(.timedOut)
            },
            lrclib: nil,
            hasAccessibilityPermission: true,
            ax: nil
        ))

        let first = await provider.lyrics(for: track())
        let second = await provider.lyrics(for: track())

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .unavailable)

        XCTAssertEqual(calls.values, [
            "appleScript",
            "requiresAX",
            "mediaToken",
            "appleMusicWeb",
            "lrclib",
            "hasAX",
            "ax",
            "retryAX",
            "appleScript",
            "requiresAX",
            "mediaToken",
            "appleMusicWeb",
            "lrclib",
            "hasAX",
            "ax",
            "retryAX"
        ])
    }

    func testLookupIDIsSharedAcrossProviderStages() async {
        let calls = CallLog()
        var webLookupID: String?
        var lrclibLookupID: String?
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            fetchAppleMusicWebLyrics: { _, lookupID in
                webLookupID = lookupID
                return nil
            },
            lrclib: nil,
            fetchLRCLIBLyrics: { _, lookupID in
                lrclibLookupID = lookupID
                return nil
            },
            hasAccessibilityPermission: false,
            ax: nil
        ))

        _ = await provider.lyrics(for: track())

        XCTAssertFalse(webLookupID?.isEmpty ?? true)
        XCTAssertEqual(webLookupID, lrclibLookupID)
    }

    func testUnavailableCacheExpires() async {
        let calls = CallLog()
        var currentDate = Date()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            requiresAccessibilityPermission: false,
            mediaUserTokenConfigured: true,
            appleMusicWeb: nil,
            lrclib: nil,
            hasAccessibilityPermission: true,
            ax: nil,
            now: { currentDate }
        ))

        let first = await provider.lyrics(for: track())
        currentDate = currentDate.addingTimeInterval(11 * 60)
        let second = await provider.lyrics(for: track())

        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .unavailable)

        XCTAssertEqual(calls.values, [
            "appleScript", "requiresAX", "mediaToken", "appleMusicWeb", "lrclib", "hasAX", "ax", "retryAX",
            "appleScript", "requiresAX", "mediaToken", "appleMusicWeb", "lrclib", "hasAX", "ax", "retryAX"
        ])
    }

    func testConcurrentSameTrackLookupJoinsInFlightTask() async {
        let calls = CallLog()
        let gate = OneShotGate()
        let provider = PublicLyricsProvider(dependencies: dependencies(
            calls: calls,
            appleScript: nil,
            fetchAppleScriptLyrics: {
                await gate.wait()
                return self.document(source: .musicApp, text: "Library lyrics")
            },
            mediaUserTokenConfigured: true,
            appleMusicWeb: document(source: .appleMusicWeb, text: "Web lyrics", timed: true),
            lrclib: document(source: .lrclib, text: "LRCLIB lyrics", timed: true),
            hasAccessibilityPermission: true,
            ax: document(source: .musicAppUI, text: "AX lyrics")
        ))

        let first = Task { await provider.lyrics(for: track()) }
        while !gate.isWaiting {
            await Task.yield()
        }
        let second = Task { await provider.lyrics(for: track()) }
        await Task.yield()
        gate.resume()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult, .available(document(source: .musicApp, text: "Library lyrics")))
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertEqual(calls.values, ["appleScript"])
    }

    private func dependencies(
        calls: CallLog,
        appleScript: LyricsDocument?,
        fetchAppleScriptLyrics: (@MainActor () async -> LyricsDocument?)? = nil,
        requiresAccessibilityPermission: Bool = false,
        mediaUserTokenConfigured: Bool,
        appleMusicWeb: LyricsDocument?,
        fetchAppleMusicWebLyrics: (@MainActor (NowPlayingTrack, String) async throws -> LyricsDocument?)? = nil,
        lrclib: LyricsDocument?,
        fetchLRCLIBLyrics: (@MainActor (NowPlayingTrack, String) async throws -> LyricsDocument?)? = nil,
        hasAccessibilityPermission: Bool,
        ax: LyricsDocument?,
        now: @escaping @MainActor () -> Date = { Date() }
    ) -> PublicLyricsProvider.Dependencies {
        PublicLyricsProvider.Dependencies(
            fetchAppleScriptLyrics: {
                calls.append("appleScript")
                if let fetchAppleScriptLyrics {
                    return await fetchAppleScriptLyrics()
                }
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
            fetchAppleMusicWebLyrics: { track, lookupID in
                calls.append("appleMusicWeb")
                if let fetchAppleMusicWebLyrics {
                    return try await fetchAppleMusicWebLyrics(track, lookupID)
                }
                return appleMusicWeb
            },
            isLRCLIBFallbackEnabled: {
                true
            },
            fetchLRCLIBLyrics: { track, lookupID in
                calls.append("lrclib")
                if let fetchLRCLIBLyrics {
                    return try await fetchLRCLIBLyrics(track, lookupID)
                }
                return lrclib
            },
            fetchAXLyrics: {
                calls.append("ax")
                return ax
            },
            sleep: { _ in
                calls.append("sleep")
            },
            now: {
                now()
            }
        )
    }

    private final class CallLog {
        private(set) var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }
    }

    private final class OneShotGate {
        private var continuation: CheckedContinuation<Void, Never>?

        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
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
