import XCTest
@testable import MusicFloat
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

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

    func testInstalledPairThatThrowsNotInstalledRequestsDownload() async {
        #if ENABLE_APPLE_TRANSLATION
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .installed },
            translate: { _, _, _ in throw TranslationError.notInstalled }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.needsDownload(source: "en", target: "fr")))
        #endif
    }

    func testInstalledPairCode16DownloadFailureRequestsDownload() async {
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .installed },
            translate: { _, _, _ in
                throw NSError(
                    domain: "TranslationErrorDomain",
                    code: 16,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to Translate"]
                )
            }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.needsDownload(source: "en", target: "fr")))
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
            translate: { _, _, _ in XCTFail("Matching source/target should not translate"); return [] },
            inferSourceLanguageIdentifier: { _ in "en" }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "en-US")

        XCTAssertEqual(result, .status(.sourceEqualsTarget))
    }

    func testSuspiciousMatchingSourceTargetMetadataUsesInferredSourceLanguage() async {
        var availabilitySource: String?
        var translationSource: String?
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { source, _ in
                availabilitySource = source.minimalIdentifier
                return .installed
            },
            translate: { source, target, requests in
                translationSource = source.minimalIdentifier
                return [
                    TranslationResponsePayload(
                        lineID: requests[0].lineID,
                        sourceLanguageIdentifier: source.minimalIdentifier,
                        targetLanguageIdentifier: target.minimalIdentifier,
                        text: "Years later, I was near the Scandalo"
                    )
                ]
            },
            inferSourceLanguageIdentifier: { _ in "fr" }
        ))

        let result = await provider.translation(
            for: document(
                lines: [
                    LyricLine(
                        id: 5,
                        text: "Des annees plus tard, j'etais vers le Scandalo",
                        startTime: nil
                    )
                ],
                sourceLanguageIdentifier: "en"
            ),
            targetLanguageIdentifier: "en"
        )

        XCTAssertEqual(availabilitySource, "fr")
        XCTAssertEqual(translationSource, "fr")
        XCTAssertEqual(result, .available(LyricTranslation(
            targetLanguageIdentifier: "en",
            sourceLanguageIdentifier: "fr",
            lines: [
                TranslatedLyricLine(
                    id: 0,
                    sourceLineID: 5,
                    text: "Years later, I was near the Scandalo"
                )
            ]
        )))
    }

    func testUnsupportedInferredSourceIsRejectedBeforeAvailabilityPreflight() async {
        var checkedAvailability = false
        var translated = false
        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in
                checkedAvailability = true
                return .installed
            },
            translate: { _, _, _ in
                translated = true
                return []
            },
            inferSourceLanguageIdentifier: { _ in "ca" },
            supportedLanguages: {
                [
                    Locale.Language(identifier: "en"),
                    Locale.Language(identifier: "fr")
                ]
            }
        ))

        let result = await provider.translation(
            for: document(
                lines: [
                    LyricLine(
                        id: 5,
                        text: "Anys mes tard, era prop del Scandalo",
                        startTime: nil
                    )
                ],
                sourceLanguageIdentifier: "en"
            ),
            targetLanguageIdentifier: "en"
        )

        XCTAssertEqual(result, .status(.unsupported(source: "ca", target: "en")))
        XCTAssertFalse(checkedAvailability)
        XCTAssertFalse(translated)
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

    func testLyricsDocumentDoesNotInferSourceLanguageDuringInitialization() {
        let document = LyricsDocument(
            source: .mock,
            lines: [
                LyricLine(
                    id: 0,
                    text: "Hello there, this mock lyric line is intentionally long enough for language detection.",
                    startTime: nil
                )
            ],
            isTimed: false
        )

        XCTAssertNil(document.sourceLanguageIdentifier)
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

    func testTranslationFailureIncludesSanitizedReason() async {
        struct StubFailure: LocalizedError {
            var errorDescription: String? { "session unavailable" }
        }

        let provider = AppleTranslationProvider(dependencies: .init(
            availability: { _, _ in .installed },
            translate: { _, _, _ in throw StubFailure() }
        ))

        let result = await provider.translation(for: document(), targetLanguageIdentifier: "fr")

        XCTAssertEqual(result, .status(.failed("Translation failed: session unavailable")))
    }

    private func document(
        lines: [LyricLine] = [LyricLine(id: 0, text: "Hello there", startTime: nil)],
        sourceLanguageIdentifier: String? = "en"
    ) -> LyricsDocument {
        LyricsDocument(
            source: .musicApp,
            lines: lines,
            isTimed: false,
            sourceLanguageIdentifier: sourceLanguageIdentifier
        )
    }
}
