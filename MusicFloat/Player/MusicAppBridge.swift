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
                var lastEmittedTrackID: String?
                var lastEmittedElapsed: TimeInterval = 0
                var lastEmittedAt = Date()

                for await event in stream {
                    // Notifications do not carry `player position`. Refine with
                    // AppleScript only when the snapshot agrees with the event
                    // track; during skips Music.app can briefly report the old
                    // current track, and mixing that elapsed time with the new
                    // track makes lyrics look many lines behind.
                    var refined = event
                    var refineOK = false
                    let isNewTrackEvent = event.track?.id != nil && event.track?.id != lastEmittedTrackID

                    if event.playbackStatus != .stopped {
                        let maxAttempts = isNewTrackEvent ? 1 : 3
                        for attempt in 0..<maxAttempts {
                            if attempt > 0 {
                                try? await Task.sleep(nanoseconds: UInt64(attempt) * 250_000_000)
                            }
                            guard let snapshot = Self.pullSnapshot() else {
                                continue
                            }
                            if let eventTrack = event.track,
                               let snapshotTrack = snapshot.track,
                               eventTrack.id != snapshotTrack.id {
                                AppTelemetry.performance.info("Music snapshot lagged new-track event; starting lyrics fetch without stale elapsed")
                                continue
                            }
                            refined = PlayerState(
                                playbackStatus: event.playbackStatus,
                                track: event.track ?? snapshot.track,
                                elapsedTime: snapshot.elapsedTime,
                                updatedAt: Date()
                            )
                            refineOK = true
                            break
                        }
                    }

                    // If we still couldn't refine and this is the SAME track
                    // we last emitted (just a state change), don't reset
                    // elapsed to 0 — extrapolate from last known instead.
                    if !refineOK,
                       event.playbackStatus == .playing,
                       let lastID = lastEmittedTrackID,
                       event.track?.id == lastID {
                        let extrapolated = lastEmittedElapsed + Date().timeIntervalSince(lastEmittedAt)
                        refined = PlayerState(
                            playbackStatus: .playing,
                            track: event.track,
                            elapsedTime: max(0, extrapolated),
                            updatedAt: Date()
                        )
                    }

                    continuation.yield(refined)
                    lastEmittedTrackID = refined.track?.id
                    lastEmittedElapsed = refined.elapsedTime
                    lastEmittedAt = Date()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - AppleScript snapshot

    private static let snapshotScript = """
    try
        launch application id "com.apple.Music"
        tell application id "com.apple.Music"
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
    on error errMsg
        return "__ERR__||" & errMsg
    end try
    """

    /// Parses an AppleScript-emitted number string. Tolerates both POSIX
    /// (`42.587`) and locale forms with a decimal comma (`42,587`).
    /// Returns 0 when the input is empty or unparseable.
    nonisolated static func parseLocaleNumber(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        if let v = Double(trimmed) { return v }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    @MainActor
    private static func pullSnapshot() -> PlayerState? {
        guard AppleMusicEventListener.isMusicAppRunning else { return nil }
        guard let raw = AppleScriptRunner.runString(snapshotScript), !raw.isEmpty else {
            return nil
        }
        let parts = raw.components(separatedBy: "||")
        let stateString = parts.first ?? "stopped"
        if stateString == "__ERR__" {
            let msg = parts.count > 1 ? parts[1] : "unknown"
            AppTelemetry.performance.error("Music snapshot script error: \(msg, privacy: .public)")
            return nil
        }
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
        // AppleScript serializes numbers using the user's locale (e.g.
        // "42,587" in many EU locales). Normalize to period decimal before
        // handing to Swift's Double initializer, which expects POSIX form.
        let duration = parseLocaleNumber(parts.count > 4 ? parts[4] : "")
        let elapsed = parseLocaleNumber(parts.count > 5 ? parts[5] : "")
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
