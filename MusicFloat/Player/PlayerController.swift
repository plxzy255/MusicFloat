import Foundation
import OSLog

@MainActor
final class PlayerController {
    private static let commandRefreshAttempts = 6
    private static let commandRefreshDelayNanoseconds: UInt64 = 200_000_000
    private static let hiddenIdleRefreshInterval: TimeInterval = 60
    /// How often we re-pull `player position` from Music.app while live and
    /// playing, to correct any drift that has accumulated since the last
    /// distributed-notification event.
    private static let resyncInterval: TimeInterval = 1.0
    /// Threshold for snapping our interpolated elapsedTime to Music's
    /// authoritative position. Smaller deltas are ignored so jitter from
    /// AppleScript's coarse `player position` doesn't fight the smooth tick.
    private static let resyncSnapThreshold: TimeInterval = 0.35
    /// Threshold for treating an elapsed-time jump as a user seek/scrub rather
    /// than normal clock drift.
    private static let seekDetectionThreshold: TimeInterval = 2.0
    private static let liveLineTickCap: TimeInterval = 1.0
    private static let liveSyllableTickCap: TimeInterval = 0.12
    private static let liveTickMinimum: TimeInterval = 0.03

    private let bridge: any MusicAppBridge
    private let liveBridgeFactory: @MainActor () -> any MusicAppBridge
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveTickTask: Task<Void, Never>?
    private var liveBridge: (any MusicAppBridge)?
    private var liveTickCallback: (@MainActor () -> Void)?
    private var liveTrackChangedCallback: (@MainActor (NowPlayingTrack?) -> Void)?
    private let syncEngine = LyricsSyncEngine()

    init(
        bridge: any MusicAppBridge,
        liveBridgeFactory: @escaping @MainActor () -> any MusicAppBridge = { PublicAppleMusicAppBridge() }
    ) {
        self.bridge = bridge
        self.liveBridgeFactory = liveBridgeFactory
    }

    // MARK: - Live Apple Music

    /// Starts an event-driven feed from Apple Music's distributed notifications.
    /// Cancels any in-flight mock preview first so the two never compete.
    ///
    /// - Parameter onTrackChanged: invoked whenever the playing track's
    ///   identity changes (including the initial prime). Used by the caller
    ///   to trigger lyrics fetches.
    func startLiveAppleMusic(
        appState: AppState,
        onTrackChanged: (@MainActor (NowPlayingTrack?) -> Void)? = nil,
        onLiveTick: (@MainActor () -> Void)? = nil
    ) {
        guard liveTask == nil else { return }
        stopMockPreview(appState: appState)

        let bridge = liveBridgeFactory()
        liveBridge = bridge
        liveTickCallback = onLiveTick
        liveTrackChangedCallback = onTrackChanged
        appState.setLiveModeRunning(true)
        AppTelemetry.performance.info("Live Apple Music bridge started")

        liveTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }

            let initial = await bridge.currentState()
            appState.setMusicVolume(await bridge.currentVolume())
            AppTelemetry.performance.info(
                "Live prime: status=\(initial.playbackStatus.rawValue, privacy: .public) hasTrack=\(initial.track != nil) elapsed=\(initial.elapsedTime) musicRunning=\(AppleMusicEventListener.isMusicAppRunning)"
            )
            appState.updatePlayerState(initial)
            var lastTrackID = initial.track?.id
            self.restartLiveTick(appState: appState, onLiveTick: onLiveTick)
            onTrackChanged?(initial.track)

            for await state in bridge.events() {
                if Task.isCancelled { break }
                let previousTrackID = appState.playerState.track?.id
                let incomingTrackID = state.track?.id
                let isSameTrack = incomingTrackID != nil && incomingTrackID == previousTrackID
                let previousEffectiveElapsed = appState.effectiveElapsedTime
                let eventDelta = state.elapsedTime - previousEffectiveElapsed
                if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                    AppTelemetry.performance.debug(
                        "Live event: status=\(state.playbackStatus.rawValue, privacy: .public) trackID=\(incomingTrackID ?? "nil", privacy: .public) elapsed=\(state.elapsedTime) previousElapsed=\(previousEffectiveElapsed) delta=\(eventDelta)"
                    )
                }
                if isSameTrack, abs(eventDelta) > Self.seekDetectionThreshold {
                    AppTelemetry.performance.info(
                        "SEEK_DETECTED source=playerInfoEvent trackID=\(incomingTrackID ?? "nil", privacy: .public) previousElapsed=\(previousEffectiveElapsed) incomingElapsed=\(state.elapsedTime) delta=\(eventDelta)"
                    )
                }
                appState.updatePlayerState(state)
                if state.track?.id != lastTrackID {
                    AppTelemetry.performance.info(
                        "Live track changed previousTrackID=\(lastTrackID ?? "nil", privacy: .public) nextTrackID=\(state.track?.id ?? "nil", privacy: .public)"
                    )
                    lastTrackID = state.track?.id
                    onTrackChanged?(state.track)
                }
                // Re-sync tick to the fresh elapsedTime from the event so
                // play/pause/skip/seek doesn't leave the active line behind.
                self.restartLiveTick(appState: appState, onLiveTick: onLiveTick)
            }
            _ = self
        }
    }

    func stopLiveAppleMusic(appState: AppState? = nil) {
        guard liveTask != nil else {
            appState?.setLiveModeRunning(false)
            return
        }
        AppTelemetry.performance.info("Live Apple Music bridge stopped")
        liveTask?.cancel()
        liveTask = nil
        liveTickTask?.cancel()
        liveTickTask = nil
        liveBridge = nil
        liveTickCallback = nil
        liveTrackChangedCallback = nil
        appState?.setMusicVolume(nil)
        appState?.setPlaybackCommandInFlight(false)
        appState?.setLiveModeRunning(false)
    }

    @discardableResult
    func performLivePlaybackCommand(
        _ command: MusicPlaybackCommand,
        appState: AppState,
        isDemoMode: Bool = false
    ) async -> PlayerState? {
        let command = normalizedCommand(command, appState: appState)
        guard !isDemoMode else {
            AppTelemetry.performance.notice(
                "Playback command ignored in demo mode command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }
        guard appState.isLiveModeRunning, let liveBridge else {
            AppTelemetry.performance.notice(
                "Playback command ignored because live mode is unavailable command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }
        guard !appState.isPlaybackCommandInFlight else {
            AppTelemetry.performance.notice(
                "Playback command ignored because another command is in flight command=\(command.telemetryName, privacy: .public)"
            )
            return nil
        }

        AppTelemetry.performance.info(
            "Playback command started command=\(command.telemetryName, privacy: .public)"
        )
        appState.setPlaybackCommandInFlight(true)
        defer {
            appState.setPlaybackCommandInFlight(false)
        }

        let result = await liveBridge.perform(command)
        guard result.isSuccess else {
            logPlaybackCommandFailure(result, command: command)
            return nil
        }

        AppTelemetry.performance.info(
            "Playback command succeeded command=\(command.telemetryName, privacy: .public)"
        )

        if case .setVolume(let volume) = command {
            appState.setMusicVolume(volume)
            if let refreshedVolume = await liveBridge.currentVolume() {
                appState.setMusicVolume(refreshedVolume)
            }
            return nil
        }

        let previousTrackID = appState.playerState.track?.id
        let refreshedState = await refreshedStateAfterPlaybackCommand(
            command,
            previousTrackID: previousTrackID,
            bridge: liveBridge
        )
        appState.updatePlayerState(refreshedState)
        if refreshedState.track?.id != previousTrackID {
            liveTrackChangedCallback?(refreshedState.track)
        }
        restartLiveTick(appState: appState, onLiveTick: liveTickCallback)
        return refreshedState
    }

    private func normalizedCommand(
        _ command: MusicPlaybackCommand,
        appState: AppState
    ) -> MusicPlaybackCommand {
        switch command {
        case .seek(let position):
            return .seek(MusicPlaybackCommand.clampedPlaybackPosition(
                position,
                duration: appState.playerState.track?.duration
            ))
        default:
            return command.clamped
        }
    }

    private func refreshedStateAfterPlaybackCommand(
        _ command: MusicPlaybackCommand,
        previousTrackID: String?,
        bridge: any MusicAppBridge
    ) async -> PlayerState {
        var latestState = await bridge.currentState()

        let shouldWaitForChangedSnapshot: (PlayerState) -> Bool = { state in
            switch command {
            case .nextTrack, .previousTrack:
                guard let previousTrackID else { return false }
                return state.track?.id == previousTrackID
            case .seek(let position):
                guard let previousTrackID, state.track?.id == previousTrackID else { return false }
                return abs(state.elapsedTime - position) > 0.35
            case .playPause, .setVolume:
                return false
            }
        }

        for _ in 1..<Self.commandRefreshAttempts where shouldWaitForChangedSnapshot(latestState) {
            try? await Task.sleep(nanoseconds: Self.commandRefreshDelayNanoseconds)
            latestState = await bridge.currentState()
        }

        return latestState
    }

    private func logPlaybackCommandFailure(
        _ result: MusicPlaybackCommandResult,
        command: MusicPlaybackCommand
    ) {
        switch result {
        case .succeeded:
            break
        case .unavailable(let reason):
            AppTelemetry.performance.notice(
                "Playback command unavailable command=\(command.telemetryName, privacy: .public) reason=\(reason, privacy: .public)"
            )
        case .failed(let reason):
            AppTelemetry.performance.error(
                "Playback command failed command=\(command.telemetryName, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
    }

    /// Called by the app when overlay visibility changes so we don't burn
    /// CPU advancing a clock no one is watching.
    func overlayVisibilityChanged(_ isVisible: Bool, appState: AppState) {
        guard liveTask != nil else { return }
        if isVisible {
            restartLiveTick(appState: appState, onLiveTick: liveTickCallback)
        } else {
            liveTickTask?.cancel()
            liveTickTask = nil
        }
    }

    /// Advances live elapsed time by wall-clock delta while live mode is
    /// playing and the overlay is visible. Periodically re-pulls `player
    /// position` from Music.app to correct drift.
    private func restartLiveTick(
        appState: AppState,
        onLiveTick: (@MainActor () -> Void)? = nil
    ) {
        liveTickTask?.cancel()
        liveTickTask = nil

        guard appState.isOverlayVisible,
              appState.playerState.playbackStatus == .playing,
              appState.playerState.track != nil else {
            return
        }

        liveTickTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            var lastWall = Date()
            var elapsed = Self.liveTickInitialElapsed(appState: appState)
            // Start with `lastResync` in the past so the first resync fires
            // immediately on the next loop iteration. This catches the case
            // where AppleScript was wedged at event time but recovers by the
            // time the first tick interval has elapsed.
            var lastResync = Date(timeIntervalSinceNow: -Self.resyncInterval)
            var consecutiveResyncFailures = 0

            while !Task.isCancelled {
                // Sleep until the next lyric boundary. Syllable-timed Apple
                // lyrics need a tighter cap than line-synced documents so the
                // active word does not jump over short spans.
                let document = appState.lyricsDocument
                let nextSyllable = self.syncEngine.nextSyllableBoundary(
                    in: document,
                    after: elapsed + appState.effectiveLyricOffsetSeconds
                )
                let nextLine = self.syncEngine.nextLineStart(
                    in: document,
                    after: elapsed + appState.effectiveLyricOffsetSeconds
                )
                let nextBoundary = [nextSyllable, nextLine].compactMap { $0 }.min()
                let targetElapsed = (nextBoundary.map { $0 - appState.effectiveLyricOffsetSeconds }) ?? (elapsed + Self.liveLineTickCap)
                let targetDelta = targetElapsed - elapsed
                let tickCap = nextSyllable != nil && targetDelta <= Self.liveLineTickCap
                    ? Self.liveSyllableTickCap
                    : Self.liveLineTickCap
                let sleep = max(Self.liveTickMinimum, min(tickCap, targetDelta))
                try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
                if Task.isCancelled { return }

                let now = Date()
                elapsed += now.timeIntervalSince(lastWall)
                lastWall = now
                if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                    AppTelemetry.performance.debug(
                        "Live tick localElapsed=\(elapsed) snapshotElapsed=nil delta=nil snap=false"
                    )
                }

                // Periodic watchdog against Music.app's authoritative position.
                // While the overlay is visible this is frequent enough to catch
                // seeks even if Music.app does not post a playerInfo event.
                let resyncDue: TimeInterval = consecutiveResyncFailures > 0
                    ? min(Self.resyncInterval, 1.0 + Double(consecutiveResyncFailures) * 2.0)
                    : Self.resyncInterval
                if now.timeIntervalSince(lastResync) >= resyncDue,
                   let bridge = self.liveBridge {
                    lastResync = now
                    let snapshot = await bridge.currentState()
                    if Task.isCancelled { return }
                    if snapshot.track != nil {
                        consecutiveResyncFailures = 0
                        let snapshotDelta = snapshot.elapsedTime - elapsed
                        let isSameTrack = snapshot.track?.id == appState.playerState.track?.id
                        let shouldSnap = snapshot.playbackStatus == .playing
                            && isSameTrack
                            && abs(snapshotDelta) >= Self.resyncSnapThreshold
                        if shouldSnap || AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                            AppTelemetry.performance.info(
                                "Live tick watchdog localElapsed=\(elapsed) snapshotElapsed=\(snapshot.elapsedTime) delta=\(snapshotDelta) sameTrack=\(isSameTrack) snap=\(shouldSnap)"
                            )
                        }
                        if shouldSnap {
                            if abs(snapshotDelta) > Self.seekDetectionThreshold {
                                AppTelemetry.performance.info(
                                    "SEEK_DETECTED source=watchdog trackID=\(snapshot.track?.id ?? "nil", privacy: .public) localElapsed=\(elapsed) snapshotElapsed=\(snapshot.elapsedTime) delta=\(snapshotDelta)"
                                )
                                appState.updatePlayerState(snapshot)
                            }
                            AppTelemetry.performance.info(
                                "Live tick resync delta=\(snapshotDelta) snap=true"
                            )
                            elapsed = snapshot.elapsedTime
                            lastWall = Date()
                        }
                    } else {
                        consecutiveResyncFailures = min(consecutiveResyncFailures + 1, 5)
                        if AppTelemetry.isVerbosePlaybackTelemetryEnabled {
                            AppTelemetry.performance.debug(
                                "Live tick watchdog snapshot missing failures=\(consecutiveResyncFailures)"
                            )
                        }
                    }
                }

                guard appState.playerState.playbackStatus == .playing,
                      appState.playerState.track != nil else { return }
                appState.updateLiveElapsedTime(elapsed)
                onLiveTick?()
            }
        }
    }

    static func liveTickInitialElapsed(appState: AppState) -> TimeInterval {
        appState.effectiveElapsedTime
    }

    // MARK: - Mock Preview

    func startMockPreview(appState: AppState) {
        guard refreshTask == nil else { return }
        stopLiveAppleMusic(appState: appState)

        AppTelemetry.performance.info("Player controller mock preview started")
        appState.setMockPreviewRunning(true)
        refreshTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }

            let initialState = await bridge.currentState()
            appState.updatePlayerState(initialState)
            var playbackClock = PlaybackClock(initialState: initialState)
            var currentState = initialState

            while !Task.isCancelled {
                let refreshInterval = self.nextRefreshInterval(
                    currentState: currentState,
                    lyricsDocument: appState.lyricsDocument
                )
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: refreshInterval))
                guard !Task.isCancelled else { return }

                currentState = playbackClock.tick(by: refreshInterval)
                appState.updateLiveElapsedTime(currentState.elapsedTime)
            }
        }
    }

    func stopMockPreview(appState: AppState? = nil) {
        guard refreshTask != nil else {
            appState?.setMockPreviewRunning(false)
            return
        }

        AppTelemetry.performance.info("Player controller mock preview stopped")
        refreshTask?.cancel()
        refreshTask = nil
        appState?.setMockPreviewRunning(false)
    }

    private func nextRefreshInterval(
        currentState: PlayerState,
        lyricsDocument: LyricsDocument
    ) -> TimeInterval {
        guard currentState.playbackStatus == .playing else {
            return Self.hiddenIdleRefreshInterval
        }
        guard let nextLineStart = syncEngine.nextLineStart(
            in: lyricsDocument,
            after: currentState.elapsedTime
        ) else {
            return Self.hiddenIdleRefreshInterval
        }
        return max(0.25, nextLineStart - currentState.elapsedTime)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0.25, interval) * 1_000_000_000)
    }
}
