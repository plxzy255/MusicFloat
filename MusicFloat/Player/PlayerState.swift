import Foundation

enum PlaybackStatus: String, Equatable, Sendable {
    case stopped
    case paused
    case playing

    var displayName: String {
        switch self {
        case .stopped:
            "Stopped"
        case .paused:
            "Paused"
        case .playing:
            "Playing"
        }
    }
}

struct PlayerState: Equatable, Sendable {
    var playbackStatus: PlaybackStatus
    var track: NowPlayingTrack?
    var elapsedTime: TimeInterval
    var updatedAt: Date

    var statusLine: String {
        guard let track else {
            return "No track connected"
        }

        return "\(playbackStatus.displayName) from \(track.providerName)"
    }

    static let disconnected = PlayerState(
        playbackStatus: .stopped,
        track: nil,
        elapsedTime: 0,
        updatedAt: Date()
    )
}
