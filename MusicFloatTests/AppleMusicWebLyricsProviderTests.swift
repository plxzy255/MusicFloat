import Foundation
import XCTest
@testable import MusicFloat

@MainActor
final class AppleMusicWebLyricsProviderTests: XCTestCase {
    func testSelectBestTTMLPrefersIdentifiablePrimaryLanguage() {
        let original = AppleMusicWebLyricsProvider.TTMLVariant(
            ttml: ttml(language: "ja", text: "原文"),
            language: "ja",
            source: .primary
        )
        let preferred = AppleMusicWebLyricsProvider.TTMLVariant(
            ttml: ttml(language: "en", text: "English"),
            language: "en",
            source: .localization
        )

        let selected = AppleMusicWebLyricsProvider.selectBestTTML(
            from: [preferred, original],
            preferredLyricLanguage: "en-US",
            storefrontLanguage: "en-US"
        )

        XCTAssertEqual(selected, original)
    }

    func testDedicatedEndpointDecodesLocalizationsAndSelectsPreferredLanguage() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "en-US"),
            .dedicated(status: 200, ttml: ttml(text: "Primary"), localizations: [
                "en-US": ttml(language: "en-US", text: "Hello"),
                "fr-FR": ttml(language: "fr-FR", text: "Bonjour")
            ])
        ])
        let provider = provider(stub: stub, preferredLyricLanguage: "fr-FR")

        let document = try await provider.lyrics(for: track())

        XCTAssertEqual(document?.lines.first?.text, "Bonjour")
        let paths = await stub.requestPaths()
        XCTAssertEqual(paths[1], "/v1/catalog/us/songs/song-id/syllable-lyrics")
        let query = await stub.queryItems(forRequestAt: 1)
        XCTAssertEqual(query["extend"], "ttmlLocalizations")
        XCTAssertEqual(query["l"], "fr-fr")
    }

    func testDedicatedEndpointDoesNotSendStorefrontLanguageWithoutPreferredLyricLanguage() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "ru-RU"),
            .dedicated(status: 200, ttml: ttml(language: "en-US", text: "Original"), localizations: [
                "ru-RU": ttml(language: "ru-RU", text: "Localized")
            ])
        ])
        let provider = provider(stub: stub)

        let document = try await provider.lyrics(for: track())

        XCTAssertEqual(document?.lines.first?.text, "Original")
        let query = await stub.queryItems(forRequestAt: 1)
        XCTAssertEqual(query["extend"], "ttmlLocalizations")
        XCTAssertNil(query["l"])
    }

    func testDedicatedEndpointPrefersSyllableTimedPrimaryOverLineTimedLocalization() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "en-US"),
            .dedicated(status: 200, ttml: syllableTTML(text: "Timed lyric"), localizations: [
                "fr-FR": ttml(language: "fr-FR", text: "Preferred line")
            ])
        ])
        let provider = provider(stub: stub, preferredLyricLanguage: "fr-FR")

        let document = try await provider.lyrics(for: track())

        XCTAssertEqual(document?.lines.first?.text, "Timed lyric")
        XCTAssertEqual(document?.lines.first?.syllables.count, 2)
    }

    func testFallsBackToBroadSongsEndpointWhenDedicatedEndpoint404s() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "en-US"),
            .dedicated(status: 404, ttml: nil, localizations: [:]),
            .broad(status: 200, syllableTTML: ttml(language: "en-US", text: "Fallback lyric"))
        ])
        let provider = provider(stub: stub)

        let document = try await provider.lyrics(for: track())

        XCTAssertEqual(document?.lines.first?.text, "Fallback lyric")
        let paths = await stub.requestPaths()
        XCTAssertEqual(paths[1], "/v1/catalog/us/songs/song-id/syllable-lyrics")
        XCTAssertEqual(paths[2], "/v1/catalog/us/songs/song-id")
        let broadQuery = await stub.queryItems(forRequestAt: 2)
        XCTAssertEqual(broadQuery["include[songs]"], "albums,lyrics,syllable-lyrics")
    }

    func testBroadEndpointDoesNotSendStorefrontLanguageWithoutPreferredLyricLanguage() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "ru-RU"),
            .dedicated(status: 404, ttml: nil, localizations: [:]),
            .broad(status: 200, syllableTTML: ttml(language: "en-US", text: "Fallback lyric"))
        ])
        let provider = provider(stub: stub)

        let document = try await provider.lyrics(for: track())

        XCTAssertEqual(document?.lines.first?.text, "Fallback lyric")
        let dedicatedQuery = await stub.queryItems(forRequestAt: 1)
        let broadQuery = await stub.queryItems(forRequestAt: 2)
        XCTAssertNil(dedicatedQuery["l"])
        XCTAssertNil(broadQuery["l"])
        XCTAssertEqual(broadQuery["include[songs]"], "albums,lyrics,syllable-lyrics")
    }

    func testBroadSongsEndpoint404ReturnsNilAfterDedicatedEndpointMiss() async throws {
        let stub = AppleMusicHTTPStub(responses: [
            .storefront(language: "en-US"),
            .dedicated(status: 200, ttml: nil, localizations: [:]),
            .empty(status: 404)
        ])
        let provider = provider(stub: stub)

        let document = try await provider.lyrics(for: track())

        XCTAssertNil(document)
        let paths = await stub.requestPaths()
        XCTAssertEqual(paths[1], "/v1/catalog/us/songs/song-id/syllable-lyrics")
        XCTAssertEqual(paths[2], "/v1/catalog/us/songs/song-id")
    }

    func testCatalogMissSkipsImmediateRetry() async throws {
        let stub = AppleMusicHTTPStub(responses: [.storefront(language: "en-US")])
        var catalogCalls = 0
        let provider = AppleMusicWebLyricsProvider(
            developerToken: { _ in "developer-token" },
            mediaUserToken: { "media-user-token" },
            catalogIdentity: { _, _, _, _, _, _ in
                catalogCalls += 1
                return .miss
            },
            dataForRequest: { request in
                try await stub.data(for: request)
            }
        )

        let first = try await provider.lyrics(for: track())
        let second = try await provider.lyrics(for: track())

        XCTAssertNil(first)
        XCTAssertNil(second)

        XCTAssertEqual(catalogCalls, 1)
        let paths = await stub.requestPaths()
        XCTAssertEqual(paths, ["/v1/me/storefront"])
    }

    func testTransientCatalogFailureThrowsAndDoesNotNegativeCache() async throws {
        let stub = AppleMusicHTTPStub(responses: [.storefront(language: "en-US")])
        var catalogCalls = 0
        let provider = AppleMusicWebLyricsProvider(
            developerToken: { _ in "developer-token" },
            mediaUserToken: { "media-user-token" },
            catalogIdentity: { _, _, _, _, _, _ in
                catalogCalls += 1
                return .transientFailure
            },
            dataForRequest: { request in
                try await stub.data(for: request)
            }
        )

        for _ in 0..<2 {
            do {
                _ = try await provider.lyrics(for: track())
                XCTFail("Expected transient catalog resolution to throw")
            } catch let error as AppleMusicWebLyricsProvider.APIError {
                XCTAssertEqual(error, .transientCatalogResolution)
            }
        }

        XCTAssertEqual(catalogCalls, 2)
        let paths = await stub.requestPaths()
        XCTAssertEqual(paths, ["/v1/me/storefront"])
    }

    func testLookupIDPropagatesToCatalogResolution() async throws {
        let stub = AppleMusicHTTPStub(responses: [.storefront(language: "en-US")])
        var capturedLookupID: String?
        let provider = AppleMusicWebLyricsProvider(
            developerToken: { _ in "developer-token" },
            mediaUserToken: { "media-user-token" },
            catalogIdentity: { _, _, _, _, _, lookupID in
                capturedLookupID = lookupID
                return .miss
            },
            dataForRequest: { request in
                try await stub.data(for: request)
            }
        )

        _ = try await provider.lyrics(for: track(), lookupID: "lookup-123")

        XCTAssertEqual(capturedLookupID, "lookup-123")
    }

    private func provider(
        stub: AppleMusicHTTPStub,
        preferredLyricLanguage: String? = nil
    ) -> AppleMusicWebLyricsProvider {
        AppleMusicWebLyricsProvider(
            developerToken: { _ in "developer-token" },
            mediaUserToken: { "media-user-token" },
            catalogIdentity: { _, _, _, storefront, _, _ in
                .identity(AppleMusicCatalogResolver.Identity(storefront: storefront ?? "us", songID: "song-id"))
            },
            dataForRequest: { request in
                try await stub.data(for: request)
            },
            preferredLyricLanguage: {
                preferredLyricLanguage
            }
        )
    }

    private func track() -> NowPlayingTrack {
        NowPlayingTrack(
            id: "track-1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            providerName: "Music"
        )
    }
}

private actor AppleMusicHTTPStub {
    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw AppleMusicWebLyricsProvider.APIError.emptyResponse
        }
        let next = responses.removeFirst()
        let url = request.url ?? URL(string: "https://amp-api.music.apple.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: next.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (try next.data(), response)
    }

    func requestPaths() -> [String] {
        requests.map { $0.url?.path ?? "" }
    }

    func queryItems(forRequestAt index: Int) -> [String: String] {
        guard requests.indices.contains(index),
              let url = requests[index].url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            guard let value = $0.value else { return nil }
            return ($0.name, value)
        })
    }

    struct Response {
        let status: Int
        let payload: [String: Any]

        func data() throws -> Data {
            try JSONSerialization.data(withJSONObject: payload)
        }

        static func storefront(language: String) -> Response {
            Response(status: 200, payload: [
                "data": [[
                    "id": "us",
                    "attributes": ["defaultLanguageTag": language]
                ]]
            ])
        }

        static func dedicated(
            status: Int,
            ttml: String?,
            localizations: [String: String]
        ) -> Response {
            var attributes: [String: Any] = [:]
            if let ttml {
                attributes["ttml"] = ttml
            }
            if !localizations.isEmpty {
                attributes["ttmlLocalizations"] = localizations
            }
            return Response(status: status, payload: [
                "data": [[
                    "id": "song-id",
                    "type": "syllable-lyrics",
                    "attributes": attributes
                ]]
            ])
        }

        static func broad(status: Int, syllableTTML: String) -> Response {
            Response(status: status, payload: [
                "data": [[
                    "relationships": [
                        "syllable-lyrics": [
                            "data": [[
                                "attributes": [
                                    "ttml": syllableTTML
                                ]
                            ]]
                        ]
                    ]
                ]]
            ])
        }

        static func empty(status: Int) -> Response {
            Response(status: status, payload: [:])
        }
    }
}

private func ttml(language: String? = nil, text: String) -> String {
    let languageAttribute = language.map { #" xml:lang="\#($0)""# } ?? ""
    return """
    <tt xmlns="http://www.w3.org/ns/ttml"\(languageAttribute)>
      <body>
        <div>
          <p begin="0.000" end="2.000">\(text)</p>
        </div>
      </body>
    </tt>
    """
}

private func syllableTTML(language: String? = nil, text: String) -> String {
    let languageAttribute = language.map { #" xml:lang="\#($0)""# } ?? ""
    let split = text.split(separator: " ", maxSplits: 1).map(String.init)
    let first = split.first ?? text
    let second = split.dropFirst().first.map { " \($0)" } ?? ""
    return """
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal"\(languageAttribute) itunes:timing="Word">
      <body>
        <div>
          <p begin="0.000" end="2.000">
            <span begin="0.000" end="1.000">\(first)</span><span begin="1.000" end="2.000">\(second)</span>
          </p>
        </div>
      </body>
    </tt>
    """
}
