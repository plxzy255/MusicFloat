import XCTest
@testable import MusicFloat

@MainActor
final class TTMLParserTests: XCTestCase {
    @MainActor
    func testParsesLineAndSyllableTimings() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
          <body>
            <div>
              <p begin="00:01.500" end="00:04.000">
                <span begin="00:01.500" end="00:02.000">Hel</span><span begin="00:02.000" end="00:02.500">lo</span>
              </p>
              <p begin="00:05.250" end="00:07.750">Line level only</p>
            </div>
          </body>
        </tt>
        """

        let document = TTMLParser.parse(ttml: ttml)

        XCTAssertEqual(document?.source, .appleMusicWeb)
        XCTAssertEqual(document?.isTimed, true)
        XCTAssertEqual(document?.lines.count, 2)
        XCTAssertEqual(document?.lines[0].text, "Hello")
        XCTAssertEqual(document?.lines[0].startTime, 1.5)
        XCTAssertEqual(document?.lines[0].endTime, 4.0)
        XCTAssertEqual(document?.lines[0].syllables, [
            LyricSyllable(text: "Hel", startTime: 1.5, endTime: 2.0),
            LyricSyllable(text: "lo", startTime: 2.0, endTime: 2.5)
        ])
        XCTAssertEqual(document?.lines[1].text, "Line level only")
        XCTAssertEqual(document?.lines[1].startTime, 5.25)
        XCTAssertEqual(document?.lines[1].endTime, 7.75)
        XCTAssertEqual(document?.lines[1].syllables, [])
    }

    @MainActor
    func testParsesHourMinuteSecondAndSecondsTimecodes() {
        XCTAssertEqual(TTMLParser.parseTimecode("01:02:03.456"), 3723.456)
        XCTAssertEqual(TTMLParser.parseTimecode("02:03.250"), 123.25)
        XCTAssertEqual(TTMLParser.parseTimecode("4.5s"), 4.5)
    }
}
