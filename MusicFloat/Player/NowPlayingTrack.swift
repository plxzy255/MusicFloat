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
}
