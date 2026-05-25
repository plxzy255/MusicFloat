import XCTest
@testable import MusicFloat

final class LyricsParserTests: XCTestCase {
    @MainActor
    func testPlainParserKeepsSentenceLineTogether() throws {
        let document = try XCTUnwrap(LyricsParser.parsePlain("One complete sentence, not word chunks.", source: .lrclib))

        XCTAssertEqual(document.isTimed, false)
        XCTAssertEqual(document.lines.count, 1)
        XCTAssertEqual(document.lines.first?.text, "One complete sentence, not word chunks.")
        XCTAssertEqual(document.lines.first?.startTime, nil)
    }

    @MainActor
    func testPlainParserNormalizesCRLFAndDropsBlankLines() throws {
        let raw = " First line \r\n\r\nSecond line\rThird line  "

        let document = try XCTUnwrap(LyricsParser.parsePlain(raw, source: .musicApp))

        XCTAssertEqual(document.lines.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(document.lines.map(\.id), [0, 1, 2])
        XCTAssertFalse(document.isTimed)
    }

    @MainActor
    func testParseFallsBackToPlainWhenSyncedHasNoValidTimestamp() throws {
        let document = try XCTUnwrap(LyricsParser.parse(
            synced: "[not-a-time] keep me whole",
            plain: "Plain fallback line",
            source: .lrclib
        ))

        XCTAssertFalse(document.isTimed)
        XCTAssertEqual(document.lines.map(\.text), ["Plain fallback line"])
    }

    @MainActor
    func testLRCParsesOffsetAndFractionalTimestamps() throws {
        let raw = """
        [offset:+250]
        [00:01.50]First timed line
        [00:03.005]Second timed line
        """

        let document = try XCTUnwrap(LyricsParser.parseLRC(raw, source: .lrclib))

        XCTAssertTrue(document.isTimed)
        XCTAssertEqual(document.lines.map(\.text), ["First timed line", "Second timed line"])
        let firstStart = try XCTUnwrap(document.lines[0].startTime)
        let secondStart = try XCTUnwrap(document.lines[1].startTime)
        XCTAssertEqual(firstStart, 1.75, accuracy: 0.0001)
        XCTAssertEqual(secondStart, 3.255, accuracy: 0.0001)
    }

    @MainActor
    func testLRCRepeatedTimestampsKeepStableLineOrder() throws {
        let raw = """
        [00:10.00]First repeated line
        [00:10.00]Second repeated line
        [00:12.00]Later line
        """

        let document = try XCTUnwrap(LyricsParser.parseLRC(raw, source: .lrclib))

        XCTAssertEqual(document.lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(document.lines.map(\.text), [
            "First repeated line",
            "Second repeated line",
            "Later line"
        ])
        let starts = try document.lines.map { try XCTUnwrap($0.startTime) }
        XCTAssertEqual(starts, [10, 10, 12])
    }
}
