import OSLog
import SwiftUI

@main
@MainActor
struct MusicFloatApp: App {
    @State private var appState = AppState()
    private let panelController = FloatingPanelController()
    private let playerController: PlayerController
    private let providerPipelineController: ProviderPipelineController

    init() {
        // Player bridge defaults to mock until the user explicitly enables
        // "Listen to Apple Music". Lyrics provider is wired to the public
        // path so that when live mode is on, real lyrics are fetched.
        var flags = RuntimeFeatureFlags.architectureDefault
        flags.lyricsProviderMode = .publicApple
        flags.translationProviderMode = .publicApple
        let adapters = RuntimeAdapterFactory.makeAdapters(for: flags)
        playerController = PlayerController(bridge: adapters.musicBridge)
        providerPipelineController = ProviderPipelineController(
            lyricsProvider: adapters.lyricsProvider,
            translationProvider: adapters.translationProvider
        )
        AppTelemetry.lifecycle.info("MusicFloat app initialized")
    }

    var body: some Scene {
        MenuBarExtra("MusicFloat", systemImage: "music.note") {
            MenuBarView(
                appState: appState,
                toggleOverlay: toggleOverlay,
                toggleMockPreview: toggleMockPreview,
                toggleLiveAppleMusic: toggleLiveAppleMusic,
                nudgeLyricOffset: { [appState] delta in appState.nudgeLyricOffset(by: delta) },
                resetLyricOffset: { [appState] in appState.resetLyricOffset() },
                clearAllPerTrackOffsets: { [appState] in appState.clearAllPerTrackOffsets() },
                resetMockPlayback: resetMockPlayback,
                setOverlayContentState: setOverlayContentState,
                quit: quit
            )
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(appState: appState)
        }
    }

    private func toggleOverlay() {
        appState.isOverlayVisible.toggle()
        AppTelemetry.menuBar.info("Toggle overlay requested visible=\(self.appState.isOverlayVisible)")

        if appState.isOverlayVisible {
            if !appState.isLiveModeRunning {
                playerController.startMockPreview(appState: appState)
            }
            providerPipelineController.prepareOverlayContent(appState: appState)
            panelController.show(appState: appState)
            playerController.overlayVisibilityChanged(true, appState: appState)
        } else {
            providerPipelineController.stopHiddenWork(appState: appState)
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
        if appState.isLiveModeRunning {
            playerController.stopLiveAppleMusic(appState: appState)
            providerPipelineController.stopHiddenWork(appState: appState)
        } else {
            playerController.startLiveAppleMusic(appState: appState) { [appState, providerPipelineController] track in
                guard track != nil else {
                    AppTelemetry.performance.info("Live track payload empty; preserving current lyrics state")
                    providerPipelineController.cancelInFlightLoadPreservingState()
                    return
                }
                providerPipelineController.refreshOverlayContent(appState: appState)
            } onLiveTick: { [appState, providerPipelineController] in
                providerPipelineController.refreshIntegratedVisibleLyrics(appState: appState)
            }
        }
    }

    private func resetMockPlayback() {
        appState.resetMockPlayback()
    }

    private func setOverlayContentState(_ state: OverlayContentState) {
        appState.setOverlayContentState(state)
    }

    private func quit() {
        AppTelemetry.lifecycle.info("Quit requested from menu bar")
        providerPipelineController.stopHiddenWork(appState: appState)
        playerController.stopMockPreview(appState: appState)
        playerController.stopLiveAppleMusic(appState: appState)
        panelController.hide()
        NSApplication.shared.terminate(nil)
    }
}
