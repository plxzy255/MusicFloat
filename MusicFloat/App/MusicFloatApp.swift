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
        let adapters = RuntimeAdapterFactory.makeAdapters(for: RuntimeFeatureFlags.architectureDefault)
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
            playerController.startMockPreview(appState: appState)
            providerPipelineController.prepareOverlayContent(appState: appState)
            panelController.show(appState: appState)
        } else {
            providerPipelineController.stopHiddenWork(appState: appState)
            playerController.stopMockPreview(appState: appState)
            playerController.stopLiveAppleMusic(appState: appState)
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
        } else {
            playerController.startLiveAppleMusic(appState: appState)
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
