import Foundation
import OSLog

@MainActor
final class PlayerController {
    private static let hiddenIdleRefreshInterval: TimeInterval = 60

    private let bridge: any MusicAppBridge
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var liveBridge: (any MusicAppBridge)?
    private let syncEngine = LyricsSyncEngine()

    init(bridge: any MusicAppBridge = MockMusicAppBridge()) {
        self.bridge = bridge
    }

    // MARK: - Live Apple Music

    /// Starts an event-driven feed from Apple Music's distributed notifications.
    /// Cancels any in-flight mock preview first so the two never compete.
    func startLiveAppleMusic(appState: AppState) {
        guard liveTask == nil else { return }
        stopMockPreview(appState: appState)

        let bridge = PublicAppleMusicAppBridge()
        liveBridge = bridge
        appState.setLiveModeRunning(true)
        AppTelemetry.performance.info("Live Apple Music bridge started")

        liveTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }

            // Prime with current state so the overlay reflects what's
            // already playing instead of waiting for the next event.
            let initial = await bridge.currentState()
            appState.updatePlayerState(initial)

            for await state in bridge.events() {
                if Task.isCancelled { break }
                appState.updatePlayerState(state)
            }
            _ = self // retain self for the lifetime of the loop
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
        liveBridge = nil
        appState?.setLiveModeRunning(false)
    }

    func startMockPreview(appState: AppState) {
        guard refreshTask == nil else {
            return
        }
        stopLiveAppleMusic(appState: appState)

        AppTelemetry.performance.info("Player controller mock preview started")
        appState.setMockPreviewRunning(true)
        refreshTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else {
                return
            }

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
                guard !Task.isCancelled else {
                    return
                }

                currentState = playbackClock.tick(by: refreshInterval)
                appState.updatePlayerState(currentState)
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
