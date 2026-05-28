import XCTest
@testable import MusicFloat

@MainActor
final class LyricsTimingDiagnosticsTests: XCTestCase {
    func testSummaryReportsTimedShapeWithoutRawLyricText() {
        let document = LyricsDocument(
            source: .appleMusicWeb,
            lines: [
                LyricLine(
                    id: 10,
                    text: "private first lyric",
                    startTime: 3,
                    endTime: 4,
                    syllables: [
                        LyricSyllable(text: "private ", startTime: 3, endTime: 3.4),
                        LyricSyllable(text: "first", startTime: 3.4, endTime: 4)
                    ]
                ),
                LyricLine(
                    id: 11,
                    text: "private second lyric",
                    startTime: 9,
                    endTime: 10.5
                )
            ],
            isTimed: true,
            sourceLanguageIdentifier: "en-US"
        )

        let summary = LyricsTimingDiagnostics.summary(
            for: document,
            elapsedTime: 3.2,
            duration: 30
        )

        XCTAssertEqual(summary.source, .appleMusicWeb)
        XCTAssertEqual(summary.sourceLanguageIdentifier, "en")
        XCTAssertEqual(summary.lineCount, 2)
        XCTAssertEqual(summary.timedLineCount, 2)
        XCTAssertEqual(summary.lineEndCount, 2)
        XCTAssertEqual(summary.syllableCount, 2)
        XCTAssertEqual(summary.hasWordTiming, true)
        XCTAssertEqual(summary.hasLineEndTiming, true)
        XCTAssertEqual(summary.activeLineID, 10)
        XCTAssertEqual(summary.activeLineIndex, 0)
        XCTAssertEqual(summary.nextLineStartMilliseconds, 9_000)
        XCTAssertEqual(summary.nextSyllableBoundaryMilliseconds, 3_400)
        XCTAssertEqual(summary.firstLineStartMilliseconds, 3_000)
        XCTAssertEqual(summary.lastLineStartMilliseconds, 9_000)
        XCTAssertEqual(summary.lastLineEndMilliseconds, 10_500)
        XCTAssertEqual(summary.leadingGapMilliseconds, 3_000)
        XCTAssertEqual(summary.trailingGapMilliseconds, 19_500)
        XCTAssertEqual(summary.interlineGapCount, 1)
        XCTAssertEqual(summary.longInterlineGapCount, 1)
        XCTAssertEqual(summary.maxInterlineGapMilliseconds, 5_000)
        XCTAssertEqual(summary.overlapCount, 0)
        XCTAssertFalse(String(describing: summary).contains("private first lyric"))
        XCTAssertFalse(String(describing: summary).contains("private second lyric"))
    }

    func testSummaryUsesOffsetCorrectedEffectiveLyricClock() {
        let document = LyricsDocument(
            source: .lrclib,
            lines: [
                LyricLine(id: 20, text: "first", startTime: 10),
                LyricLine(id: 21, text: "second", startTime: 20),
                LyricLine(id: 22, text: "third", startTime: 30)
            ],
            isTimed: true,
            offsetCorrection: 1.5
        )

        let summary = LyricsTimingDiagnostics.summary(
            for: document,
            elapsedTime: 17,
            duration: 60,
            lyricOffsetSeconds: 2
        )

        XCTAssertEqual(summary.effectiveLyricTimeMilliseconds, 20_500)
        XCTAssertEqual(summary.offsetCorrectionMilliseconds, 1_500)
        XCTAssertEqual(summary.activeLineID, 21)
        XCTAssertEqual(summary.activeLineIndex, 1)
        XCTAssertEqual(summary.nextLineStartMilliseconds, 30_000)
    }

    func testSummaryEstimatesUntimedLineSlotsFromDuration() {
        let document = LyricsDocument(
            source: .publicProvider,
            lines: [
                LyricLine(id: 0, text: "one", startTime: nil),
                LyricLine(id: 1, text: "two", startTime: nil),
                LyricLine(id: 2, text: "three", startTime: nil),
                LyricLine(id: 3, text: "four", startTime: nil)
            ],
            isTimed: false
        )

        let summary = LyricsTimingDiagnostics.summary(
            for: document,
            elapsedTime: 41,
            duration: 80
        )

        XCTAssertEqual(summary.timedLineCount, 0)
        XCTAssertEqual(summary.lineEndCount, 0)
        XCTAssertEqual(summary.estimatedUntimedLineDurationMilliseconds, 20_000)
        XCTAssertEqual(summary.activeLineID, 2)
        XCTAssertEqual(summary.activeLineIndex, 2)
        XCTAssertNil(summary.nextLineStartMilliseconds)
        XCTAssertNil(summary.nextSyllableBoundaryMilliseconds)
    }

    func testSummaryCountsOverlappingTimedLines() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 5, endTime: 8),
                LyricLine(id: 1, text: "second", startTime: 7, endTime: 9),
                LyricLine(id: 2, text: "third", startTime: 12, endTime: 13)
            ],
            isTimed: true
        )

        let summary = LyricsTimingDiagnostics.summary(
            for: document,
            elapsedTime: 7.5,
            duration: 20
        )

        XCTAssertEqual(summary.overlapCount, 1)
        XCTAssertEqual(summary.interlineGapCount, 1)
        XCTAssertEqual(summary.maxInterlineGapMilliseconds, 3_000)
        XCTAssertEqual(summary.longInterlineGapCount, 1)
    }
}
