import AppKit
import OSLog
import SwiftUI

@main
@MainActor
struct MusicFloatApp: App {
    private let appController = MusicFloatAppController()

    var body: some Scene {
        Settings {
            SettingsView(
                appState: appController.appState,
                onTranslationPreferencesChanged: appController.translationPreferencesChanged,
                onTranslationPreparationCompleted: appController.retryTranslationAfterPreparation
            )
        }
    }
}

@MainActor
private final class MusicFloatAppController {
    let appState: AppState

    private let launchesInDemoMode = CommandLine.arguments.contains("--demo")
    private let liveProviderPipelineControllerStore: LiveProviderPipelineControllerStore
    private let panelController: FloatingPanelController
    private let playerController: PlayerController
    private let mockProviderPipelineController: ProviderPipelineController
    private let artworkProvider: AppleMusicArtworkProvider
    private let statusItemController: MenuBarStatusItemController
    private let settingsWindowController: SettingsWindowController

    init() {
        appState = AppState()
        liveProviderPipelineControllerStore = LiveProviderPipelineControllerStore()
        panelController = FloatingPanelController()

        let mockAdapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)
        playerController = PlayerController(bridge: mockAdapters.musicBridge)
        mockProviderPipelineController = ProviderPipelineController(
            lyricsProvider: mockAdapters.lyricsProvider,
            translationProvider: mockAdapters.translationProvider
        )
        artworkProvider = AppleMusicArtworkProvider()
        statusItemController = MenuBarStatusItemController()
        settingsWindowController = SettingsWindowController()

        statusItemController.install(
            appState: appState,
            commands: MenuBarStatusItemCommands(
                toggleOverlay: { [weak self] in self?.toggleOverlay() },
                toggleMockPreview: { [weak self] in self?.toggleMockPreview() },
                toggleLiveAppleMusic: { [weak self] in self?.toggleLiveAppleMusic() },
                nudgeLyricOffset: { [weak self] delta in self?.nudgeLyricOffset(by: delta) },
                resetLyricOffset: { [weak self] in self?.resetLyricOffset() },
                clearAllPerTrackOffsets: { [weak self] in self?.clearAllPerTrackOffsets() },
                resetMockPlayback: { [weak self] in self?.resetMockPlayback() },
                setOverlayContentState: { [weak self] state in self?.setOverlayContentState(state) },
                openSettings: { [weak self] in self?.openSettingsWindow() },
                quit: { [weak self] in self?.quit() }
            )
        )

        AppTelemetry.lifecycle.info("MusicFloat app initialized")

        applyStartupMode()
    }

    private func applyStartupMode() {
        let arguments = CommandLine.arguments

        if launchesInDemoMode {
            AppTelemetry.lifecycle.info("Demo mode requested - auto-starting overlay with mock preview in 500ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                self?.toggleOverlay()
            }
            return
        }

        if arguments.contains("--live") {
            AppTelemetry.lifecycle.info("Live mode requested - auto-starting Live Apple Music mode and overlay in 500ms")
        } else {
            AppTelemetry.lifecycle.info("Default startup - auto-starting Live Apple Music mode and overlay in 500ms")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            self?.startLiveAppleMusic()
        }
    }

    private func openSettingsWindow() {
        settingsWindowController.show(
            appState: appState,
            onTranslationPreferencesChanged: { [weak self] in self?.translationPreferencesChanged() },
            onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() }
        )
    }

    private func nudgeLyricOffset(by delta: Double) {
        appState.nudgeLyricOffset(by: delta)
    }

    private func resetLyricOffset() {
        appState.resetLyricOffset()
    }

    private func clearAllPerTrackOffsets() {
        appState.clearAllPerTrackOffsets()
    }

    private func toggleOverlay() {
        appState.isOverlayVisible.toggle()
        AppTelemetry.menuBar.info("Toggle overlay requested visible=\(self.appState.isOverlayVisible)")

        if appState.isOverlayVisible {
            if !appState.isLiveModeRunning {
                playerController.startMockPreview(appState: appState)
            }
            activeProviderPipelineController.prepareOverlayContent(appState: appState)
            panelController.show(
                appState: appState,
                onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
                playbackCommands: overlayPlaybackCommands
            )
            playerController.overlayVisibilityChanged(true, appState: appState)
        } else {
            mockProviderPipelineController.stopHiddenWork(appState: appState)
            liveProviderPipelineControllerStore.current?.stopHiddenWork(appState: appState)
            playerController.stopMockPreview(appState: appState)
            playerController.overlayVisibilityChanged(false, appState: appState)
            panelController.hide(releaseResources: appState.reduceHiddenMemoryUsage)
        }
    }

    private func toggleMockPreview() {
        if appState.isMockPreviewRunning {
            playerController.stopMockPreview(appState: appState)
        } else {
            playerController.startMockPreview(appState: appState)
        }
    }

    private func toggleLiveAppleMusic() {
        guard !launchesInDemoMode else {
            AppTelemetry.menuBar.notice("Live Apple Music toggle ignored in demo mode")
            statusItemController.refreshStatusIcon()
            return
        }

        if appState.isLiveModeRunning {
            playerController.stopLiveAppleMusic(appState: appState)
            liveProviderPipelineControllerStore.current?.stopHiddenWork(appState: appState)
            artworkProvider.cancel(appState: appState) { [weak self] in
                self?.statusItemController.refreshStatusIcon()
            }
            appState.runtimeFeatureFlags = .architectureDefault
        } else {
            startLiveAppleMusic()
        }

        statusItemController.refreshStatusIcon()
    }

    private func startLiveAppleMusic() {
        guard !appState.isLiveModeRunning else { return }

        let liveProviderPipelineController = getLiveProviderPipelineController()
        appState.runtimeFeatureFlags = .liveAppleMusic
        showOverlayForLiveAppleMusicIfNeeded()
        playerController.startLiveAppleMusic(appState: appState) { [weak self, appState, artworkProvider, liveProviderPipelineController] track in
            artworkProvider.refreshArtwork(for: track, appState: appState) { [weak self] in
                self?.statusItemController.refreshStatusIcon()
            }
            guard track != nil else {
                AppTelemetry.performance.info("Live track payload empty; preserving current lyrics state")
                liveProviderPipelineController.cancelInFlightLoadPreservingState(appState: appState)
                return
            }
            guard appState.isOverlayVisible || appState.runtimeFeatureFlags.allowsHiddenProviderRefresh else {
                liveProviderPipelineController.cancelInFlightLoadPreservingState(appState: appState)
                AppTelemetry.performance.info("Live track refresh deferred while overlay hidden")
                return
            }
            liveProviderPipelineController.refreshOverlayContentForLiveTrack(appState: appState)
            self?.statusItemController.refreshStatusIcon()
        } onLiveTick: { [appState, liveProviderPipelineController] in
            liveProviderPipelineController.refreshIntegratedVisibleLyrics(appState: appState)
        }
    }

    private func showOverlayForLiveAppleMusicIfNeeded() {
        guard !appState.isOverlayVisible else { return }
        appState.isOverlayVisible = true
        AppTelemetry.windowing.notice("Showing lyrics overlay for Live Apple Music")
        panelController.show(
            appState: appState,
            onTranslationPreparationCompleted: { [weak self] in self?.retryTranslationAfterPreparation() },
            playbackCommands: overlayPlaybackCommands
        )
        playerController.overlayVisibilityChanged(true, appState: appState)
    }

    private var overlayPlaybackCommands: LyricsOverlayPlaybackCommands {
        LyricsOverlayPlaybackCommands(
            playPause: { [weak self] in self?.performPlaybackCommand(.playPause) },
            previousTrack: { [weak self] in self?.performPlaybackCommand(.previousTrack) },
            nextTrack: { [weak self] in self?.performPlaybackCommand(.nextTrack) },
            setVolume: { [weak self] volume in self?.performPlaybackCommand(.setVolume(volume)) },
            seek: { [weak self] position in self?.performPlaybackCommand(.seek(position)) }
        )
    }

    private func performPlaybackCommand(_ command: MusicPlaybackCommand) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await playerController.performLivePlaybackCommand(
                command,
                appState: appState,
                isDemoMode: launchesInDemoMode
            )
            statusItemController.refreshStatusIcon()
        }
    }

    private func resetMockPlayback() {
        appState.resetMockPlayback()
        statusItemController.refreshStatusIcon()
    }

    private func setOverlayContentState(_ state: OverlayContentState) {
        appState.setOverlayContentState(state)
    }

    func translationPreferencesChanged() {
        guard appState.isOverlayVisible else { return }
        activeProviderPipelineController.refreshTranslation(appState: appState)
    }

    func retryTranslationAfterPreparation() {
        guard appState.isOverlayVisible,
              appState.playerState.track != nil else {
            return
        }
        activeProviderPipelineController.refreshTranslation(appState: appState)
    }

    private func quit() {
        AppTelemetry.lifecycle.info("Quit requested from menu bar")
        mockProviderPipelineController.stopHiddenWork(appState: appState)
        liveProviderPipelineControllerStore.current?.stopHiddenWork(appState: appState)
        playerController.stopMockPreview(appState: appState)
        playerController.stopLiveAppleMusic(appState: appState)
        artworkProvider.cancel(appState: appState) { [weak self] in
            self?.statusItemController.refreshStatusIcon()
        }
        panelController.hide()
        NSApplication.shared.terminate(nil)
    }

    private var activeProviderPipelineController: ProviderPipelineController {
        appState.isLiveModeRunning ? getLiveProviderPipelineController() : mockProviderPipelineController
    }

    private func getLiveProviderPipelineController() -> ProviderPipelineController {
        liveProviderPipelineControllerStore.get()
    }
}

@MainActor
private final class LiveProviderPipelineControllerStore {
    private(set) var current: ProviderPipelineController?

    func get() -> ProviderPipelineController {
        if let current {
            return current
        }

        let liveAdapters = RuntimeAdapterFactory.makeAdapters(for: .liveAppleMusic)
        let controller = ProviderPipelineController(
            lyricsProvider: liveAdapters.lyricsProvider,
            translationProvider: liveAdapters.translationProvider
        )
        current = controller
        AppTelemetry.lifecycle.info("Live provider pipeline initialized")
        return controller
    }
}
