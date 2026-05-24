import Foundation
import OSLog

/// Mints the developer JWT used by Apple Music's web player.
///
/// The web player at `music.apple.com` bundles its own developer token inside
/// its main JS asset. The token rotates every ~6 months. We do exactly what
/// the web player does: scrape the asset URL out of the landing HTML, then
/// scrape the `eyJh…` bearer string out of the JS bundle. Cached on disk
/// (UserDefaults) keyed by an `exp`-aware validity window so we don't
/// re-scrape on every fetch.
@MainActor
final class AppleMusicTokenBootstrap {
    static let shared = AppleMusicTokenBootstrap()

    private let cacheKey = "AppleMusicDeveloperToken.v1"
    private let cacheExpKey = "AppleMusicDeveloperToken.v1.exp"
    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    /// Returns a valid Bearer token, refreshing it from the web player when
    /// the cached one is missing, expired, or `forceRefresh == true` (call
    /// after a 401/403 from the catalog API).
    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let cached = cachedToken(), !isExpired(cached) {
            return cached.value
        }
        let fresh = try await fetchFromWebPlayer()
        store(fresh)
        return fresh.value
    }

    // MARK: - Cache

    private struct CachedToken {
        let value: String
        let expiresAt: Date?
    }

    private func cachedToken() -> CachedToken? {
        guard let value = defaults.string(forKey: cacheKey), !value.isEmpty else { return nil }
        let expEpoch = defaults.double(forKey: cacheExpKey)
        let expiresAt = expEpoch > 0 ? Date(timeIntervalSince1970: expEpoch) : nil
        return CachedToken(value: value, expiresAt: expiresAt)
    }

    private func store(_ token: CachedToken) {
        defaults.set(token.value, forKey: cacheKey)
        if let exp = token.expiresAt {
            defaults.set(exp.timeIntervalSince1970, forKey: cacheExpKey)
        } else {
            defaults.removeObject(forKey: cacheExpKey)
        }
    }

    private func isExpired(_ token: CachedToken) -> Bool {
        guard let exp = token.expiresAt else { return false }
        // Refresh a day before the JWT actually expires.
        return Date() >= exp.addingTimeInterval(-86_400)
    }

    // MARK: - Scrape

    enum BootstrapError: Error {
        case landingFetchFailed
        case indexAssetNotFound
        case assetFetchFailed
        case tokenNotFound
    }

    private func fetchFromWebPlayer() async throws -> CachedToken {
        AppTelemetry.performance.info("Apple Music dev-token bootstrap: fetching landing")
        var req = URLRequest(url: URL(string: "https://music.apple.com/us/browse")!)
        req.timeoutInterval = 6
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        let (landingData, landingResponse) = try await session.data(for: req)
        guard let landingHTTP = landingResponse as? HTTPURLResponse,
              (200...299).contains(landingHTTP.statusCode),
              let landingHTML = String(data: landingData, encoding: .utf8) else {
            throw BootstrapError.landingFetchFailed
        }

        // Web player's main bundle is referenced as e.g. `index-abc123.js`.
        // Match the asset URL itself so we don't have to guess the prefix.
        let assetURL = try extractAssetURL(from: landingHTML)
        AppTelemetry.performance.info("Apple Music dev-token bootstrap: asset=\(assetURL.absoluteString, privacy: .public)")

        var assetReq = URLRequest(url: assetURL)
        assetReq.timeoutInterval = 8
        assetReq.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (assetData, assetResponse) = try await session.data(for: assetReq)
        guard let assetHTTP = assetResponse as? HTTPURLResponse,
              (200...299).contains(assetHTTP.statusCode),
              let assetJS = String(data: assetData, encoding: .utf8) else {
            throw BootstrapError.assetFetchFailed
        }

        guard let jwt = extractJWT(from: assetJS) else {
            throw BootstrapError.tokenNotFound
        }
        let expiresAt = decodeJWTExpiry(jwt)
        AppTelemetry.performance.info("Apple Music dev-token bootstrap: minted exp=\(expiresAt?.timeIntervalSince1970 ?? -1)")
        return CachedToken(value: jwt, expiresAt: expiresAt)
    }

    private func extractAssetURL(from html: String) throws -> URL {
        // Apple has shipped `index-<hash>.js`, `index.<hash>.js`, and (currently)
        // `index~<hash>.js`. Match any of them, then any other index-ish asset
        // as a final fallback.
        let patterns = [
            #"/assets/index[~\-.][A-Za-z0-9_.\-]+?\.js"#,
            #"/assets/[A-Za-z0-9_./~\-]*index[A-Za-z0-9_./~\-]*?\.js"#
        ]
        for pattern in patterns {
            if let range = html.range(of: pattern, options: .regularExpression) {
                let path = String(html[range])
                if let url = URL(string: "https://music.apple.com\(path)") {
                    return url
                }
            }
        }
        throw BootstrapError.indexAssetNotFound
    }

    private func extractJWT(from js: String) -> String? {
        // JWTs always start with `eyJh` (base64url of `{"a` for alg header).
        // The web bundle inlines the token as a quoted string literal. Match
        // the longest run of valid JWT characters after the prefix.
        let pattern = #"eyJh[A-Za-z0-9._\-]+"#
        guard let range = js.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let candidate = String(js[range])
        // A real JWT has two dots and at least three segments.
        return candidate.filter { $0 == "." }.count >= 2 ? candidate : nil
    }

    nonisolated func decodeJWTExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payload = String(parts[1])
        guard let data = base64URLDecode(payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    nonisolated private func base64URLDecode(_ s: String) -> Data? {
        var padded = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let mod = padded.count % 4
        if mod != 0 { padded.append(String(repeating: "=", count: 4 - mod)) }
        return Data(base64Encoded: padded)
    }
}
