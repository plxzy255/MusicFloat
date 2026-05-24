import OSLog
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

    let toggleOverlay: () -> Void
    let toggleMockPreview: () -> Void
    let toggleLiveAppleMusic: () -> Void
    let nudgeLyricOffset: (Double) -> Void
    let resetLyricOffset: () -> Void
    let clearAllPerTrackOffsets: () -> Void
    let resetMockPlayback: () -> Void
    let setOverlayContentState: (OverlayContentState) -> Void
    let quit: () -> Void

    private var offsetMenuLabel: String {
        let value = formattedOffset(appState.effectiveLyricOffsetSeconds)
        switch appState.lyricOffsetScope {
        case .perTrack: return "\(value), this track"
        case .global: return "\(value), global"
        }
    }

    private func formattedOffset(_ seconds: Double) -> String {
        let roundedTenths = Int((seconds * 10).rounded())
        let sign = roundedTenths < 0 ? "-" : "+"
        let magnitude = abs(roundedTenths)
        return "\(sign)\(magnitude / 10).\(magnitude % 10)s"
    }

    private var resetLabel: String {
        switch appState.lyricOffsetScope {
        case .perTrack: return "Reset This Track (Use Global)"
        case .global: return "Reset Global to 0"
        }
    }

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

        Text("Translation: \(appState.translationRuntimeState.displayName)")
            .foregroundStyle(.secondary)

        Text(appState.playerState.track?.displayTitle ?? "No current track")
            .foregroundStyle(.secondary)

        Divider()

        Button(appState.isLiveModeRunning ? "Stop Listening to Apple Music" : "Listen to Apple Music") {
            AppTelemetry.menuBar.info("Toggle live Apple Music requested running=\(!appState.isLiveModeRunning)")
            toggleLiveAppleMusic()
        }

        Menu("Lyric Offset (\(offsetMenuLabel))") {
            Button("Nudge Earlier −0.5s") { nudgeLyricOffset(-0.5) }
                .keyboardShortcut("[")
            Button("Nudge Later +0.5s") { nudgeLyricOffset(0.5) }
                .keyboardShortcut("]")
            Button("Nudge Earlier −2s") { nudgeLyricOffset(-2.0) }
            Button("Nudge Later +2s") { nudgeLyricOffset(2.0) }
            Divider()
            Button(resetLabel) { resetLyricOffset() }
            Button("Clear All Per-Track Offsets (\(appState.perTrackOffsets.count))") {
                clearAllPerTrackOffsets()
            }
            .disabled(appState.perTrackOffsets.isEmpty)
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
        nudgeLyricOffset: { _ in },
        resetLyricOffset: {},
        clearAllPerTrackOffsets: {},
        resetMockPlayback: {},
        setOverlayContentState: { _ in },
        quit: {}
    )
}
