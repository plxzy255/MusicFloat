import AppKit
import ImageIO
import XCTest
@testable import MusicFloat

final class AppStateArtworkTests: XCTestCase {
    @MainActor
    func testLyricsAndTranslationClearWhenTrackChanges() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.lyricsClearOnTrackChange.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let secondTrack = NowPlayingTrack(
            id: "track-b",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let oldDocument = LyricsDocument(
            source: .appleMusicWeb,
            lines: [LyricLine(id: 0, text: "Old lyric should not leak", startTime: 10)],
            isTimed: true,
            sourceLanguageIdentifier: "en"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 12,
            updatedAt: Date()
        ))
        appState.applyLyricsDocument(oldDocument)
        appState.applyTranslation(LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 0, text: "Ancienne ligne")]
        ))
        appState.applyProviderReady()

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: secondTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        XCTAssertEqual(appState.lyricsDocument.source, .none)
        XCTAssertTrue(appState.lyricsDocument.lines.isEmpty)
        XCTAssertTrue(appState.translation.lines.isEmpty)
        XCTAssertFalse(appState.overlaySnapshot.lyricText.contains("Old lyric should not leak"))
    }

    @MainActor
    func testLyricsArePreservedForTransientNilTrackPayload() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.lyricsPreserveNilTrack.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let track = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let document = LyricsDocument(
            source: .musicAppUI,
            lines: [LyricLine(id: 0, text: "Keep this transiently", startTime: nil)],
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 12,
            updatedAt: Date()
        ))
        appState.applyLyricsDocument(document)
        appState.applyProviderReady()

        appState.updatePlayerState(PlayerState(
            playbackStatus: .paused,
            track: nil,
            elapsedTime: 12,
            updatedAt: Date()
        ))

        XCTAssertEqual(appState.lyricsDocument, document)
        XCTAssertEqual(appState.overlaySnapshot.lyricText, "Keep this transiently")
    }

    @MainActor
    func testNowPlayingArtworkClearsWhenTrackChanges() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkClears.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let secondTrack = NowPlayingTrack(
            id: "track-b",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 4, height: 4)), forTrackID: firstTrack.id)

        XCTAssertNotNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, firstTrack.id)

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: secondTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, secondTrack.id)
    }

    @MainActor
    func testStaleNowPlayingArtworkIsIgnored() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkStale.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let firstTrack = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )
        let secondTrack = NowPlayingTrack(
            id: "track-b",
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: firstTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: secondTrack,
            elapsedTime: 0,
            updatedAt: Date()
        ))

        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 4, height: 4)), forTrackID: firstTrack.id)

        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertEqual(appState.nowPlayingArtworkTrackID, secondTrack.id)
    }

    @MainActor
    func testClearingArtworkRemovesTrackAssociation() {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkClearAssociation.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        let track = NowPlayingTrack(
            id: "track-a",
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Test"
        )

        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        appState.applyNowPlayingArtwork(NSImage(size: NSSize(width: 4, height: 4)), forTrackID: track.id)

        appState.clearNowPlayingArtwork()

        XCTAssertNil(appState.nowPlayingArtwork)
        XCTAssertNil(appState.nowPlayingArtworkTrackID)
    }

    @MainActor
    func testArtworkDownsamplingKeepsLargestPixelDimensionWithinLimit() async throws {
        let sourceData = try makeImageData(width: 1024, height: 768)

        let maybeThumbnailData = await ArtworkImageProcessor.downsampledImageData(
            from: sourceData,
            maxPixelSize: 256
        )
        let thumbnailData = try XCTUnwrap(maybeThumbnailData)
        let pixelSize = try imagePixelSize(from: thumbnailData)

        XCTAssertLessThanOrEqual(max(pixelSize.width, pixelSize.height), 256)
        XCTAssertGreaterThan(pixelSize.width, 0)
        XCTAssertGreaterThan(pixelSize.height, 0)
    }

    @MainActor
    func testArtworkDownsamplingPreservesAlreadySmallSourceData() async throws {
        let sourceData = try makeJPEGImageData(width: 128, height: 128)
        let sourcePixelSize = try imagePixelSize(from: sourceData)

        let maybeThumbnailData = await ArtworkImageProcessor.downsampledImageData(
            from: sourceData,
            maxPixelSize: 256
        )
        let thumbnailData = try XCTUnwrap(maybeThumbnailData)
        let pixelSize = try imagePixelSize(from: thumbnailData)

        XCTAssertLessThanOrEqual(max(sourcePixelSize.width, sourcePixelSize.height), 256)
        XCTAssertEqual(thumbnailData, sourceData)
        XCTAssertEqual(pixelSize.width, sourcePixelSize.width)
        XCTAssertEqual(pixelSize.height, sourcePixelSize.height)
    }

    @MainActor
    func testArtworkProviderCachesThumbnailDataForSameTrack() async throws {
        let defaults = UserDefaults(suiteName: "MusicFloatTests.artworkProviderCache.\(UUID().uuidString)")!
        let appState = AppState(userDefaults: defaults)
        appState.setLiveModeRunning(true)
        let track = NowPlayingTrack(
            id: "Artist|Album|Private Title",
            title: "Private Title",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Apple Music"
        )
        appState.updatePlayerState(PlayerState(
            playbackStatus: .playing,
            track: track,
            elapsedTime: 0,
            updatedAt: Date()
        ))
        let sourceData = try makeImageData(width: 16, height: 16)
        var providerRequests = 0
        let provider = AppleMusicArtworkProvider(
            mediaCache: EphemeralMediaCache(policy: MediaCachePolicy(maxEntries: 4, maxTotalCost: 128 * 1024)),
            artworkDataProvider: {
                providerRequests += 1
                return sourceData
            }
        )

        let firstApplied = expectation(description: "First artwork applied")
        provider.refreshArtwork(for: track, appState: appState) {
            if appState.nowPlayingArtwork != nil {
                firstApplied.fulfill()
            }
        }
        await fulfillment(of: [firstApplied], timeout: 1.0)
        XCTAssertEqual(providerRequests, 1)

        let secondApplied = expectation(description: "Second artwork applied from cache")
        provider.refreshArtwork(for: track, appState: appState) {
            if appState.nowPlayingArtwork != nil {
                secondApplied.fulfill()
            }
        }
        await fulfillment(of: [secondApplied], timeout: 1.0)

        XCTAssertEqual(providerRequests, 1)
        XCTAssertNotNil(appState.nowPlayingArtwork)
    }

    @MainActor
    func testArtworkCacheKeyDoesNotExposeRawTrackIdentity() {
        let track = NowPlayingTrack(
            id: "Artist|Album|Private Title",
            title: "Private Title",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Apple Music"
        )

        let key = AppleMusicArtworkProvider.artworkCacheKey(for: track)

        XCTAssertEqual(key.namespace, .artwork)
        XCTAssertEqual(key.rawValue, AppleMusicArtworkProvider.artworkCacheKey(for: track).rawValue)
        XCTAssertTrue(key.rawValue.hasPrefix("artwork-v1:"))
        XCTAssertFalse(key.rawValue.contains("Private Title"))
        XCTAssertFalse(key.rawValue.contains("Artist"))
        XCTAssertFalse(key.rawValue.contains("Album"))
    }

    @MainActor
    private func makeImageData(width: Int, height: Int) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemPink.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        image.unlockFocus()

        guard let data = image.tiffRepresentation else {
            throw TestImageError.makeImageFailed
        }

        return data
    }

    @MainActor
    private func makeJPEGImageData(width: Int, height: Int) throws -> Data {
        let tiffData = try makeImageData(width: width, height: height)
        guard let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw TestImageError.makeImageFailed
        }

        return data
    }

    private func imagePixelSize(from data: Data) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw TestImageError.readPropertiesFailed
        }

        return (width, height)
    }

    private enum TestImageError: Error {
        case makeImageFailed
        case readPropertiesFailed
    }
}
