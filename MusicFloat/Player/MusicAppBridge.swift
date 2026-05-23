import Foundation
import OSLog

@MainActor
protocol MusicAppBridge {
    var displayName: String { get }

    /// Returns the current snapshot of player state. May be slow if it has to
    /// touch the underlying app (e.g. AppleScript). Use only on explicit demand
    /// or as a primer; prefer `events()` for steady-state updates.
    func currentState() async -> PlayerState

    /// A long-running stream of state updates. The default implementation
    /// returns an immediately-finished stream so mock/disabled bridges do not
    /// have to opt in.
    func events() -> AsyncStream<PlayerState>
}

extension MusicAppBridge {
    func events() -> AsyncStream<PlayerState> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

struct MockMusicAppBridge: MusicAppBridge {
    let displayName = "Mock Music bridge"

    func currentState() async -> PlayerState {
        Self.previewState
    }

    static let previewTrack = NowPlayingTrack(
        id: "mock:musicfloat:architecture-preview",
        title: "Architecture Preview",
        artist: "MusicFloat",
        album: "Native Boundaries",
        duration: 132,
        providerName: "Mock"
    )

    static let previewState = PlayerState(
        playbackStatus: .playing,
        track: previewTrack,
        elapsedTime: 42,
        updatedAt: Date()
    )
}

/// Real Apple Music bridge.
///
/// Sources:
/// - Steady-state updates via `com.apple.Music.playerInfo` distributed
///   notifications (event-driven, no polling).
/// - Snapshot pulls via AppleScript for `player position`, which the
///   notification does not carry.
///
/// Behavior is gated on Music.app actually being running; if it is not, we
/// return a disconnected state and avoid AppleScript so we do not launch it.
struct PublicAppleMusicAppBridge: MusicAppBridge {
    let displayName = "Public Apple API bridge"

    func currentState() async -> PlayerState {
        guard AppleMusicEventListener.isMusicAppRunning else {
            return .disconnected
        }
        return await MainActor.run { Self.pullSnapshot() } ?? .disconnected
    }

    func events() -> AsyncStream<PlayerState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let stream = AppleMusicEventListener.makeStream()
            let task = Task { @MainActor in
                for await event in stream {
                    // Notifications do not carry `player position`. Refine by
                    // one quick AppleScript pull so the overlay starts the
                    // playback clock at the right offset on track change /
                    // resume.
                    var refined = event
                    if event.playbackStatus != .stopped,
                       let snapshot = Self.pullSnapshot() {
                        refined = PlayerState(
                            playbackStatus: event.playbackStatus,
                            track: event.track ?? snapshot.track,
                            elapsedTime: snapshot.elapsedTime,
                            updatedAt: Date()
                        )
                    }
                    continuation.yield(refined)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - AppleScript snapshot

    private static let snapshotScript = """
    tell application "Music"
        if it is not running then return ""
        set pState to (player state as string)
        if pState is "playing" or pState is "paused" then
            set tName to name of current track
            set tArtist to artist of current track
            set tAlbum to album of current track
            set tDur to duration of current track
            set tID to (persistent ID of current track as string)
            set pPos to player position
            return pState & "||" & tName & "||" & tArtist & "||" & tAlbum & "||" & (tDur as string) & "||" & (pPos as string) & "||" & tID
        else
            return pState & "||||||||||||"
        end if
    end tell
    """

    @MainActor
    private static func pullSnapshot() -> PlayerState? {
        guard AppleMusicEventListener.isMusicAppRunning else { return nil }
        guard let raw = AppleScriptRunner.runString(snapshotScript), !raw.isEmpty else {
            return nil
        }
        let parts = raw.components(separatedBy: "||")
        let stateString = parts.first ?? "stopped"
        let status: PlaybackStatus = {
            switch stateString.lowercased() {
            case "playing": return .playing
            case "paused": return .paused
            default: return .stopped
            }
        }()

        let title = parts.count > 1 ? parts[1] : ""
        let artist = parts.count > 2 ? parts[2] : ""
        let album = parts.count > 3 ? parts[3] : ""
        let duration = Double(parts.count > 4 ? parts[4] : "") ?? 0
        let elapsed = Double(parts.count > 5 ? parts[5] : "") ?? 0
        let persistentID = parts.count > 6 ? parts[6] : ""

        if title.isEmpty {
            return PlayerState(
                playbackStatus: status,
                track: nil,
                elapsedTime: 0,
                updatedAt: Date()
            )
        }

        let track = NowPlayingTrack(
            id: persistentID.isEmpty ? "\(artist)|\(album)|\(title)" : persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            providerName: AppleMusicEventListener.providerName
        )

        return PlayerState(
            playbackStatus: status,
            track: track,
            elapsedTime: elapsed,
            updatedAt: Date()
        )
    }
}

struct ExperimentalMusicAppBridge: MusicAppBridge {
    let displayName = "Experimental Music.app bridge"

    func currentState() async -> PlayerState {
        .disconnected
    }
}

struct DisabledMusicAppBridge: MusicAppBridge {
    let displayName = "Disabled music bridge"

    func currentState() async -> PlayerState {
        .disconnected
    }
}
