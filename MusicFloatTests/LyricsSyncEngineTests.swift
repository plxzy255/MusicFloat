import XCTest
@testable import MusicFloat

final class LyricsSyncEngineTests: XCTestCase {
    @MainActor
    func testTimedDocumentReturnsLatestStartedLine() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 5),
                LyricLine(id: 1, text: "second", startTime: 10),
                LyricLine(id: 2, text: "third", startTime: 20)
            ],
            isTimed: true
        )

        let activeLine = LyricsSyncEngine().activeLine(in: document, at: 12)

        XCTAssertEqual(activeLine?.id, 1)
    }

    @MainActor
    func testTimedDocumentReturnsNilBeforeFirstLineStarts() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 5),
                LyricLine(id: 1, text: "second", startTime: 10)
            ],
            isTimed: true
        )

        XCTAssertNil(LyricsSyncEngine().activeLine(in: document, at: 4.9))
    }

    @MainActor
    func testUntimedDocumentReturnsFirstLine() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: nil),
                LyricLine(id: 1, text: "second", startTime: nil)
            ],
            isTimed: false
        )

        let activeLine = LyricsSyncEngine().activeLine(in: document, at: 90)

        XCTAssertEqual(activeLine?.id, 0)
    }

    @MainActor
    func testUntimedDocumentEstimatesActiveLineFromTrackDuration() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "short", startTime: nil),
                LyricLine(id: 1, text: "a much longer plain lyric line", startTime: nil),
                LyricLine(id: 2, text: "ending", startTime: nil)
            ],
            isTimed: false
        )

        let activeLine = LyricsSyncEngine().activeLine(in: document, at: 30, duration: 60)

        XCTAssertEqual(activeLine?.id, 1)
    }

    @MainActor
    func testUntimedDocumentUsesLineSlotsInsteadOfWordWeighting() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "a very long untimed lyric sentence that should not occupy half the song", startTime: nil),
                LyricLine(id: 1, text: "short sentence", startTime: nil),
                LyricLine(id: 2, text: "ending", startTime: nil)
            ],
            isTimed: false
        )

        let activeLine = LyricsSyncEngine().activeLine(in: document, at: 31, duration: 90)

        XCTAssertEqual(activeLine?.id, 1)
    }

    @MainActor
    func testEmptyDocumentReturnsNil() {
        let document = LyricsDocument(source: .mock, lines: [], isTimed: true)

        XCTAssertNil(LyricsSyncEngine().activeLine(in: document, at: 0))
    }

    @MainActor
    func testNextLineStartReturnsUpcomingTimedBoundary() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 0),
                LyricLine(id: 1, text: "second", startTime: 18),
                LyricLine(id: 2, text: "third", startTime: 42),
                LyricLine(id: 3, text: "fourth", startTime: 78)
            ],
            isTimed: true
        )

        XCTAssertEqual(LyricsSyncEngine().nextLineStart(in: document, after: 42), 78)
    }

    @MainActor
    func testNextLineStartReturnsNilForUntimedDocument() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: nil),
                LyricLine(id: 1, text: "second", startTime: nil)
            ],
            isTimed: false
        )

        XCTAssertNil(LyricsSyncEngine().nextLineStart(in: document, after: 0))
    }

    @MainActor
    func testNextLineStartEstimatesUpcomingUntimedBoundary() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "one", startTime: nil),
                LyricLine(id: 1, text: "two words", startTime: nil),
                LyricLine(id: 2, text: "three word line", startTime: nil)
            ],
            isTimed: false
        )

        XCTAssertEqual(LyricsSyncEngine().nextLineStart(in: document, after: 12, duration: 60), 20)
    }

    @MainActor
    func testNextSyllableBoundaryReturnsUpcomingWordEdge() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 0,
                    text: "first line",
                    startTime: 10,
                    endTime: 12,
                    syllables: [
                        LyricSyllable(text: "first ", startTime: 10, endTime: 10.4),
                        LyricSyllable(text: "line", startTime: 10.4, endTime: 11)
                    ]
                )
            ],
            isTimed: true
        )

        XCTAssertEqual(LyricsSyncEngine().nextSyllableBoundary(in: document, after: 10.2), 10.4)
        XCTAssertEqual(LyricsSyncEngine().nextSyllableBoundary(in: document, after: 10.4), 11)
    }

    @MainActor
    func testNextLineEndReturnsUpcomingTimedBoundary() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 1, endTime: 4),
                LyricLine(id: 1, text: "second", startTime: 10, endTime: 12)
            ],
            isTimed: true
        )

        XCTAssertEqual(LyricsSyncEngine().nextLineEnd(in: document, after: 3), 4)
    }

    @MainActor
    func testNextLineEndRespectsOffsetCorrection() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(id: 0, text: "offset line", startTime: 8, endTime: 10)
            ],
            isTimed: true,
            offsetCorrection: 2
        )

        XCTAssertEqual(LyricsSyncEngine().nextLineEnd(in: document, after: 7.5), 8)
    }

    @MainActor
    func testNextSyllableBoundaryRespectsOffsetCorrection() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 0,
                    text: "offset line",
                    startTime: 10,
                    syllables: [
                        LyricSyllable(text: "offset ", startTime: 10, endTime: 10.5),
                        LyricSyllable(text: "line", startTime: 10.5, endTime: 11)
                    ]
                )
            ],
            isTimed: true,
            offsetCorrection: 2
        )

        XCTAssertEqual(LyricsSyncEngine().nextSyllableBoundary(in: document, after: 8.2), 8.5)
    }

    @MainActor
    func testNextSyllableBoundaryReturnsNilForLineTimedDocument() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 10),
                LyricLine(id: 1, text: "second", startTime: 12)
            ],
            isTimed: true
        )

        XCTAssertNil(LyricsSyncEngine().nextSyllableBoundary(in: document, after: 10))
    }

    @MainActor
    func testLRCLIBCalibrationUsesEffectiveElapsedForOffset() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 10),
                LyricLine(id: 1, text: "matched line", startTime: 45),
                LyricLine(id: 2, text: "later", startTime: 80)
            ],
            isTimed: true
        )

        let calibrated = ProviderPipelineController.calibratedLRCDocument(
            current: document,
            visibleLineText: "Matched Line",
            elapsed: 42
        )

        XCTAssertEqual(calibrated?.offsetCorrection, 3)
    }
}
