import AppKit
import OSLog

@MainActor
final class AppleMusicArtworkProvider {
    private var refreshTask: Task<Void, Never>?

    func refreshArtwork(
        for track: NowPlayingTrack?,
        appState: AppState,
        onArtworkChanged: (@MainActor () -> Void)? = nil
    ) {
        refreshTask?.cancel()
        refreshTask = nil

        guard appState.isLiveModeRunning, let track else {
            appState.clearNowPlayingArtwork()
            onArtworkChanged?()
            return
        }

        appState.applyNowPlayingArtwork(nil, forTrackID: track.id)
        onArtworkChanged?()
        refreshTask = Task { @MainActor [weak appState] in
            let image = await PublicAppleMusicArtworkProvider.currentTrackArtwork()
            guard !Task.isCancelled, let appState else { return }
            appState.applyNowPlayingArtwork(image, forTrackID: track.id)
            onArtworkChanged?()
        }
    }

    func cancel(appState: AppState, onArtworkChanged: (@MainActor () -> Void)? = nil) {
        refreshTask?.cancel()
        refreshTask = nil
        appState.clearNowPlayingArtwork()
        onArtworkChanged?()
    }
}

enum PublicAppleMusicArtworkProvider {
    private static let artworkScript = """
    tell application id "com.apple.Music"
        if it is running then
            try
                set artData to data of artwork 1 of current track
                return artData
            on error
                return ""
            end try
        else
            return ""
        end if
    end tell
    """

    static func currentTrackArtwork() async -> NSImage? {
        guard await MainActor.run(body: { AppleMusicEventListener.isMusicAppRunning }) else {
            return nil
        }
        guard let data = await AppleScriptRunner.runDataOffMain(artworkScript),
              !data.isEmpty,
              let image = NSImage(data: data) else {
            await MainActor.run {
                AppTelemetry.performance.info("Music artwork unavailable from AppleScript")
            }
            return nil
        }
        return image
    }
}
