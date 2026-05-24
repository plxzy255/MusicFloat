import AppKit
import Foundation
import OSLog

/// Subscribes to `com.apple.Music.playerInfo` distributed notifications and
/// projects them into `PlayerState` snapshots.
///
/// The notification fires on play/pause and track change with a userInfo
/// dictionary containing track metadata and player state. It does NOT carry
/// player position, so callers that need an accurate elapsed time should pull
/// it via `PublicAppleMusicAppBridge.currentState()`.
@MainActor
enum AppleMusicEventListener {
    private static let notificationName = Notification.Name("com.apple.Music.playerInfo")
    private static let bundleIdentifier = "com.apple.Music"
    nonisolated static let providerName = "Apple Music"

    struct PlayerInfoEvent: Sendable {
        let state: PlayerState
        let rawSummary: String
    }

    /// An async stream of player states derived from `playerInfo` notifications.
    /// The stream terminates when the consumer cancels.
    static func makeStream() -> AsyncStream<PlayerState> {
        let eventStream = makePlayerInfoStream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                for await event in eventStream {
                    continuation.yield(event.state)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An async stream of raw-enough playerInfo events for diagnostics plus the
    /// parsed state used by production code.
    static func makePlayerInfoStream() -> AsyncStream<PlayerInfoEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let center = DistributedNotificationCenter.default()
            let observer = center.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { note in
                if let event = parse(note) {
                    continuation.yield(event)
                }
            }

            let box = ObserverBox(observer: observer)
            continuation.onTermination = { _ in
                DistributedNotificationCenter.default().removeObserver(box.observer)
            }
        }
    }

    nonisolated private final class ObserverBox: @unchecked Sendable {
        let observer: any NSObjectProtocol
        init(observer: any NSObjectProtocol) { self.observer = observer }
    }

    /// True when the Music app process is alive. Used to short-circuit
    /// AppleScript launches that would otherwise spawn Music headlessly.
    static var isMusicAppRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
            .isEmpty
    }

    // MARK: - Parsing

    nonisolated private static func parse(_ notification: Notification) -> PlayerInfoEvent? {
        let info = notification.userInfo ?? [:]

        let rawState = (info["Player State"] as? String) ?? "Stopped"
        let status: PlaybackStatus = {
            switch rawState.lowercased() {
            case "playing": return .playing
            case "paused": return .paused
            default: return .stopped
            }
        }()

        let title = (info["Name"] as? String) ?? ""
        let artist = (info["Artist"] as? String) ?? ""
        let album = (info["Album"] as? String) ?? ""

        let totalTimeMs: Double = {
            if let v = info["Total Time"] as? NSNumber { return v.doubleValue }
            if let v = info["Total Time"] as? Double { return v }
            return 0
        }()
        let duration = totalTimeMs / 1000.0

        let persistentID: String = {
            if let v = info["PersistentID"] as? NSNumber { return v.stringValue }
            if let v = info["Persistent ID"] as? String { return v }
            return "\(artist)|\(album)|\(title)"
        }()
        let rawSummary = [
            "state=\(rawState)",
            "name=\(title)",
            "artist=\(artist)",
            "album=\(album)",
            "durationMs=\(totalTimeMs)",
            "persistentID=\(persistentID)"
        ].joined(separator: " ")

        // No useful track payload and not playing → treat as disconnected.
        if title.isEmpty, status != .playing {
            let state = PlayerState(
                playbackStatus: .stopped,
                track: nil,
                elapsedTime: 0,
                updatedAt: Date()
            )
            return PlayerInfoEvent(state: state, rawSummary: rawSummary)
        }

        let track = title.isEmpty ? nil : NowPlayingTrack(
            id: persistentID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            providerName: providerName
        )

        // `playerInfo` does not include player position. Caller is expected to
        // refine elapsedTime via an on-demand AppleScript pull if needed.
        let state = PlayerState(
            playbackStatus: status,
            track: track,
            elapsedTime: 0,
            updatedAt: Date()
        )
        return PlayerInfoEvent(state: state, rawSummary: rawSummary)
    }
}
