import Foundation

struct NowPlayingTrack: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let providerName: String

    var displayTitle: String {
        if artist.isEmpty {
            title
        } else {
            "\(artist) - \(title)"
        }
    }

    nonisolated var telemetryID: String {
        Self.telemetryID(for: id)
    }

    nonisolated static func telemetryID(for rawID: String?) -> String {
        guard let rawID,
              !rawID.isEmpty else {
            return "none"
        }

        var hasher = Hasher()
        hasher.combine("now-playing-track-telemetry-v1")
        hasher.combine(rawID)
        return "track:\(String(UInt(bitPattern: hasher.finalize()), radix: 16))"
    }
}
