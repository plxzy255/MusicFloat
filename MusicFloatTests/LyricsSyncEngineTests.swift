import XCTest
@testable import MusicFloat

final class LyricsSyncEngineTests: XCTestCase {
    @MainActor
    func testTimedDocumentReturnsLatestStartedLine() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(id: 0, text: "first", startTime: 0),
                LyricLine(id: 1, text: "second", startTime: 10),
                LyricLine(id: 2, text: "third", startTime: 20)
            ],
            isTimed: true
        )

        let activeLine = LyricsSyncEngine().activeLine(in: document, at: 12)

        XCTAssertEqual(activeLine?.id, 1)
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
}
