import OSLog
import SwiftUI

@main
@MainActor
struct MusicFloatApp: App {
    @State private var appState = AppState()
    private let panelController = FloatingPanelController()
    private let playerController: PlayerController
    private let mockProviderPipelineController: ProviderPipelineController
    private let liveProviderPipelineController: ProviderPipelineController

    init() {
        let mockAdapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)
        let liveAdapters = RuntimeAdapterFactory.makeAdapters(for: .liveAppleMusic)
        playerController = PlayerController(bridge: mockAdapters.musicBridge)
        mockProviderPipelineController = ProviderPipelineController(
            lyricsProvider: mockAdapters.lyricsProvider,
            translationProvider: mockAdapters.translationProvider
        )
        liveProviderPipelineController = ProviderPipelineController(
            lyricsProvider: liveAdapters.lyricsProvider,
            translationProvider: liveAdapters.translationProvider
        )
        AppTelemetry.lifecycle.info("MusicFloat app initialized")

        if CommandLine.arguments.contains("--demo") {
            AppTelemetry.lifecycle.info("Demo mode requested — auto-starting overlay with mock preview in 500ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
                toggleOverlay()
            }
        }
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
            activeProviderPipelineController.prepareOverlayContent(appState: appState)
            panelController.show(appState: appState)
            playerController.overlayVisibilityChanged(true, appState: appState)
        } else {
            mockProviderPipelineController.stopHiddenWork(appState: appState)
            liveProviderPipelineController.stopHiddenWork(appState: appState)
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
            liveProviderPipelineController.stopHiddenWork(appState: appState)
            appState.runtimeFeatureFlags = .architectureDefault
        } else {
            appState.runtimeFeatureFlags = .liveAppleMusic
            playerController.startLiveAppleMusic(appState: appState) { [appState, liveProviderPipelineController] track in
                guard track != nil else {
                    AppTelemetry.performance.info("Live track payload empty; preserving current lyrics state")
                    liveProviderPipelineController.cancelInFlightLoadPreservingState()
                    return
                }
                guard appState.isOverlayVisible || appState.runtimeFeatureFlags.allowsHiddenProviderRefresh else {
                    liveProviderPipelineController.cancelInFlightLoadPreservingState()
                    AppTelemetry.performance.info("Live track refresh deferred while overlay hidden")
                    return
                }
                liveProviderPipelineController.refreshOverlayContent(appState: appState)
            } onLiveTick: { [appState, liveProviderPipelineController] in
                liveProviderPipelineController.refreshIntegratedVisibleLyrics(appState: appState)
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
        mockProviderPipelineController.stopHiddenWork(appState: appState)
        liveProviderPipelineController.stopHiddenWork(appState: appState)
        playerController.stopMockPreview(appState: appState)
        playerController.stopLiveAppleMusic(appState: appState)
        panelController.hide()
        NSApplication.shared.terminate(nil)
    }

    private var activeProviderPipelineController: ProviderPipelineController {
        appState.isLiveModeRunning ? liveProviderPipelineController : mockProviderPipelineController
    }
}
