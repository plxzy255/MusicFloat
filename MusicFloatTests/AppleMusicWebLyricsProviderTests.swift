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

    private func provider(
        stub: AppleMusicHTTPStub,
        preferredLyricLanguage: String? = nil
    ) -> AppleMusicWebLyricsProvider {
        AppleMusicWebLyricsProvider(
            developerToken: { _ in "developer-token" },
            mediaUserToken: { "media-user-token" },
            catalogIdentity: { _, _, _, storefront, _ in
                AppleMusicCatalogResolver.Identity(storefront: storefront ?? "us", songID: "song-id")
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
