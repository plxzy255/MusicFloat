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
    func testWordTimedSpansInferReadableSpaces() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">
          <body>
            <div>
              <p begin="00:01.000" end="00:05.000">
                <span begin="00:01.000" end="00:01.300">Yeah,</span><span begin="00:01.300" end="00:01.600">yeah,</span><span begin="00:01.600" end="00:02.000">I'm</span><span begin="00:02.000" end="00:02.300">out</span><span begin="00:02.300" end="00:02.700">that</span><span begin="00:02.700" end="00:03.200">Brooklyn</span>
              </p>
            </div>
          </body>
        </tt>
        """

        let document = TTMLParser.parse(ttml: ttml)

        XCTAssertEqual(document?.lines.first?.text, "Yeah, yeah, I'm out that Brooklyn")
        XCTAssertEqual(document?.lines.first?.syllables.map(\.text), [
            "Yeah, ",
            "yeah, ",
            "I'm ",
            "out ",
            "that ",
            "Brooklyn"
        ])
    }

    @MainActor
    func testNonWordTimedSpansDoNotInventSpacesBetweenSyllableFragments() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Syllable">
          <body>
            <div>
              <p begin="00:01.000" end="00:03.000">
                <span begin="00:01.000" end="00:01.500">Hel</span><span begin="00:01.500" end="00:02.000">lo</span>
              </p>
            </div>
          </body>
        </tt>
        """

        let document = TTMLParser.parse(ttml: ttml)

        XCTAssertEqual(document?.lines.first?.text, "Hello")
        XCTAssertEqual(document?.lines.first?.syllables.map(\.text), ["Hel", "lo"])
    }

    @MainActor
    func testWordTimedCJKSpansDoNotInferLatinSpaces() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">
          <body>
            <div>
              <p begin="00:01.000" end="00:03.000">
                <span begin="00:01.000" end="00:01.500">東京</span><span begin="00:01.500" end="00:02.000">へ</span>
              </p>
            </div>
          </body>
        </tt>
        """

        let document = TTMLParser.parse(ttml: ttml)

        XCTAssertEqual(document?.lines.first?.text, "東京へ")
        XCTAssertEqual(document?.lines.first?.syllables.map(\.text), ["東京", "へ"])
    }

    @MainActor
    func testWordTimedParentheticalAdlibSticksToPreviousWord() {
        let ttml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word">
          <body>
            <div>
              <p begin="00:01.000" end="00:04.000">
                <span begin="00:01.000" end="00:01.400">out</span><span begin="00:01.400" end="00:01.800">(Yeah)</span><span begin="00:01.800" end="00:02.400">Brooklyn</span>
              </p>
            </div>
          </body>
        </tt>
        """

        let document = TTMLParser.parse(ttml: ttml)

        XCTAssertEqual(document?.lines.first?.text, "out(Yeah) Brooklyn")
        XCTAssertEqual(document?.lines.first?.syllables.map(\.text), [
            "out",
            "(Yeah) ",
            "Brooklyn"
        ])
    }

    @MainActor
    func testParsesHourMinuteSecondAndSecondsTimecodes() {
        XCTAssertEqual(TTMLParser.parseTimecode("01:02:03.456"), 3723.456)
        XCTAssertEqual(TTMLParser.parseTimecode("02:03.250"), 123.25)
        XCTAssertEqual(TTMLParser.parseTimecode("4.5s"), 4.5)
    }
}
