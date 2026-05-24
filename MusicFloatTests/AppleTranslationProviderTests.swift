import XCTest
@testable import MusicFloat

@MainActor
final class AppleTranslationProviderTests: XCTestCase {
    func testInstalledPairReturnsTranslatedLinesKeyedToOriginalIDs() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .installed },
            translate: { _, target, requests in
                [
                    TranslationResponsePayload(
                        lineID: requests[0].lineID,
                        sourceLanguageIdentifier: "en",
                        targetLanguageIdentifier: target.minimalIdentifier,
                        text: "Bonjour"
                    ),
                    TranslationResponsePayload(
                        lineID: requests[1].lineID,
                        sourceLanguageIdentifier: "en",
                        targetLanguageIdentifier: target.minimalIdentifier,
                        text: "Au revoir"
                    )
                ]
            }
        ))

        let result = await provider.translation(
            for: document(lines: [
                LyricLine(id: 10, text: "Hello", startTime: 0),
                LyricLine(id: 12, text: "Goodbye", startTime: 3)
            ]),
            targetLanguageIdentifier: "fr"
        )

        XCTAssertEqual(result, .available(LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [
                TranslatedLyricLine(id: 0, sourceLineID: 10, text: "Bonjour"),
                TranslatedLyricLine(id: 1, sourceLineID: 12, text: "Au revoir")
            ]
        )))
    }

    func testSupportedNotInstalledReturnsNeedsDownloadAndDoesNotTranslate() async {
        var translated = false
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .supported },
            translate: { _, _, _ in
                translated = true
                return []
            }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.needsDownload(source: "en", target: "fr")))
        XCTAssertFalse(translated)
    }

    func testUnsupportedPairReturnsStatus() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .unsupported },
            translate: { _, _, _ in XCTFail("Unsupported pair should not translate"); return [] }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.unsupported(source: "en", target: "fr")))
    }

    func testSourceEqualsTargetReturnsStatus() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in XCTFail("Matching source/target should not check availability"); return .installed },
            translate: { _, _, _ in XCTFail("Matching source/target should not translate"); return [] }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "en-US")

        XCTAssertEqual(result, .status(.sourceEqualsTarget))
    }

    func testMissingSourceDetectionReturnsUnavailable() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in XCTFail("Missing source should not check availability"); return .installed },
            translate: { _, _, _ in XCTFail("Missing source should not translate"); return [] }
        ))
        let shortDocument = LyricsDocument(
            source: .musicApp,
            lines: [LyricLine(id: 0, text: "Hi", startTime: nil)],
            isTimed: false
        )

        let result = await provider.translation(for: shortDocument, targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.unavailable(reason: "Source language unavailable")))
    }

    func testFiltersEmptyAndSourceIdenticalTranslatedLines() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .installed },
            translate: { _, _, requests in
                [
                    TranslationResponsePayload(lineID: requests[0].lineID, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "fr", text: "Hello"),
                    TranslationResponsePayload(lineID: requests[1].lineID, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "fr", text: "   "),
                    TranslationResponsePayload(lineID: requests[2].lineID, sourceLanguageIdentifier: "en", targetLanguageIdentifier: "fr", text: "Bonjour")
                ]
            }
        ))

        let result = await provider.translation(
            for: document(lines: [
                LyricLine(id: 0, text: "Hello", startTime: nil),
                LyricLine(id: 1, text: "Ignored", startTime: nil),
                LyricLine(id: 2, text: "Hello again", startTime: nil)
            ]),
            targetLanguageIdentifier: "fr"
        )

        XCTAssertEqual(result, .available(LyricTranslation(
            targetLanguageIdentifier: "fr",
            sourceLanguageIdentifier: "en",
            lines: [TranslatedLyricLine(id: 0, sourceLineID: 2, text: "Bonjour")]
        )))
    }

    private func document(lines: [LyricLine] = [LyricLine(id: 0, text: "Hello there", startTime: nil)]) -> LyricsDocument {
        LyricsDocument(
            source: .musicApp,
            lines: lines,
            isTimed: false,
            sourceLanguageIdentifier: "en"
        )
    }
}
