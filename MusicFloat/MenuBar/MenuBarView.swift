import OSLog
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

    let toggleOverlay: () -> Void
    let toggleMockPreview: () -> Void
    let toggleLiveAppleMusic: () -> Void
    let resetMockPlayback: () -> Void
    let setOverlayContentState: (OverlayContentState) -> Void
    let quit: () -> Void

    var body: some View {
        Button(appState.isOverlayVisible ? "Hide Lyrics" : "Show Lyrics") {
            toggleOverlay()
        }
        .keyboardShortcut("l")

        Button("Settings...") {
            AppTelemetry.menuBar.info("Open settings requested")
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Text(appState.playerState.statusLine)
            .foregroundStyle(.secondary)

        Text("Providers: \(appState.providerRuntimeState.displayName)")
            .foregroundStyle(.secondary)

        if let track = appState.playerState.track {
            Text(track.displayTitle)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button(appState.isLiveModeRunning ? "Stop Listening to Apple Music" : "Listen to Apple Music") {
            AppTelemetry.menuBar.info("Toggle live Apple Music requested running=\(!appState.isLiveModeRunning)")
            toggleLiveAppleMusic()
        }

        Button(appState.isMockPreviewRunning ? "Stop Mock Preview" : "Start Mock Preview") {
            AppTelemetry.menuBar.info("Toggle mock preview requested running=\(!appState.isMockPreviewRunning)")
            toggleMockPreview()
        }

        Button("Reset Mock Time") {
            resetMockPlayback()
        }

        Menu("Mock Overlay State") {
            Button("Ready") {
                setOverlayContentState(.ready)
            }

            Button("Loading") {
                setOverlayContentState(.loading)
            }

            Button("Unavailable") {
                setOverlayContentState(.unavailable)
            }

            Button("Error") {
                setOverlayContentState(.failed("Mock provider failed before real integrations were enabled"))
            }
        }

        Divider()

        Button("Quit MusicFloat") {
            quit()
        }
        .keyboardShortcut("q")
    }
}

#Preview {
    MenuBarView(
        appState: AppState(),
        toggleOverlay: {},
        toggleMockPreview: {},
        toggleLiveAppleMusic: {},
        resetMockPlayback: {},
        setOverlayContentState: { _ in },
        quit: {}
    )
}
