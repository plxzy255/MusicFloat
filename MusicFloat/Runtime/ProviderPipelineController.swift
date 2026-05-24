import Foundation
import OSLog

@MainActor
final class ProviderPipelineController {
    /// Backstop poll cadence in case the AX observer doesn't fire (Music not
    /// running yet, panel closed, observer attach failed). Push notifications
    /// from `MusicAppAXObserver` drive the common case at ~event latency.
    private static let integratedVisibleLyricsRefreshInterval: TimeInterval = 2.0
    /// Cooldown after an AX-observer-driven refresh, so a burst of
    /// notifications doesn't translate into a burst of full AX traversals.
    private static let observerDrivenCooldown: TimeInterval = 0.1

    private let lyricsProvider: any LyricsProvider
    private let translationProvider: any TranslationProvider
    private var loadTask: Task<Void, Never>?
    private var lastIntegratedVisibleLyricsRefresh = Date.distantPast
    private let axObserver = MusicAppAXObserver()
    private weak var observedAppState: AppState?

    init(
        lyricsProvider: any LyricsProvider,
        translationProvider: any TranslationProvider
    ) {
        self.lyricsProvider = lyricsProvider
        self.translationProvider = translationProvider
    }

    func prepareOverlayContent(appState: AppState) {
        guard loadTask == nil else {
            return
        }

        AppTelemetry.performance.info("Provider pipeline mock load started")
        appState.setProviderRuntimeState(.loading)
        appState.setOverlayContentState(.loading)

        loadTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else {
                return
            }

            defer {
                self.loadTask = nil
            }

            guard let track = appState.playerState.track else {
                appState.applyProviderUnavailable()
                return
            }
            let requestedTrackID = track.id

            let lyricsResult = await lyricsProvider.lyrics(for: track)
            guard !Task.isCancelled else {
                return
            }
            guard appState.playerState.track?.id == requestedTrackID else {
                AppTelemetry.performance.info("Provider result ignored because live track changed before lyrics completed")
                return
            }

            switch lyricsResult {
            case .available(let document):
                appState.applyLyricsDocument(document)
                await loadTranslation(for: document, appState: appState)
            case .unavailable:
                appState.applyProviderUnavailable()
            case .failed(let message):
                appState.applyProviderFailure(message)
            }
        }
    }

    /// Cancels any in-flight load and starts a fresh one. Intended for the
    /// "track changed" signal in live mode.
    func refreshOverlayContent(appState: AppState) {
        loadTask?.cancel()
        loadTask = nil
        lastIntegratedVisibleLyricsRefresh = .distantPast
        prepareOverlayContent(appState: appState)
    }

    /// Live mode can receive transient empty playerInfo payloads while Music
    /// is paused or changing state. Preserve the current document unless the
    /// playback layer has confirmed a real track identity change.
    func refreshOverlayContentForLiveTrack(appState: AppState) {
        guard appState.playerState.track != nil else {
            cancelInFlightLoadPreservingState()
            AppTelemetry.performance.info("Live provider refresh skipped for empty track payload")
            return
        }
        refreshOverlayContent(appState: appState)
    }

    func cancelInFlightLoadPreservingState() {
        guard loadTask != nil else { return }
        AppTelemetry.performance.info("Provider pipeline load cancelled because live track payload is empty")
        loadTask?.cancel()
        loadTask = nil
    }

    func refreshIntegratedVisibleLyrics(appState: AppState) {
        startAXObserverIfNeeded(appState: appState)
        performIntegratedVisibleLyricsRefresh(
            appState: appState,
            minimumInterval: Self.integratedVisibleLyricsRefreshInterval
        )
    }

    private func performIntegratedVisibleLyricsRefresh(
        appState: AppState,
        minimumInterval: TimeInterval
    ) {
        guard appState.isOverlayVisible,
              appState.isLiveModeRunning else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastIntegratedVisibleLyricsRefresh) >= minimumInterval else {
            return
        }
        lastIntegratedVisibleLyricsRefresh = now

        let current = appState.lyricsDocument
        if current.source == .appleMusicWeb, current.isTimed {
            // Authoritative timed document straight from Apple. Do not
            // overwrite with a lagging AX scrape and do not calibrate —
            // the TTML clock IS ground truth here.
            return
        }
        if current.source == .lrclib, current.isTimed {
            // Calibration path: AX gives us ground-truth current line. Align
            // the LRC clock to it instead of replacing the (multi-line, timed)
            // document with a single-line scrape.
            guard let axText = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineText() else {
                return
            }
            calibrateLRCDocument(current: current, visibleLineText: axText, appState: appState)
            return
        }

        guard let document = MusicAppLyricsProvider.fetchCurrentVisibleLyricsLineDocument(),
              document.lines.first?.text != current.lines.first?.text else {
            return
        }

        appState.applyLyricsDocument(document)
        appState.applyProviderReady()
        AppTelemetry.performance.info("Music.app UI lyric line refreshed")
    }

    private func calibrateLRCDocument(
        current: LyricsDocument,
        visibleLineText: String,
        appState: AppState
    ) {
        let elapsed = appState.effectiveElapsedTime
        guard let calibrated = Self.calibratedLRCDocument(
            current: current,
            visibleLineText: visibleLineText,
            elapsed: elapsed
        ) else {
            return
        }

        appState.applyLyricsDocument(calibrated)
        AppTelemetry.performance.info("LRC calibrated offset=\(calibrated.offsetCorrection) (was \(current.offsetCorrection))")
    }

    static func calibratedLRCDocument(
        current: LyricsDocument,
        visibleLineText axText: String,
        elapsed: TimeInterval
    ) -> LyricsDocument? {
        guard elapsed > 0 else { return nil }

        let normalizedAX = Self.normalizeForMatch(axText)
        guard !normalizedAX.isEmpty else { return nil }

        let candidates = current.lines.compactMap { line -> (LyricLine, TimeInterval)? in
            guard let start = line.startTime else { return nil }
            guard Self.normalizeForMatch(line.text) == normalizedAX else { return nil }
            return (line, start)
        }
        guard let (matched, matchedStart) = candidates.min(by: {
            abs($0.1 - (elapsed + current.offsetCorrection)) < abs($1.1 - (elapsed + current.offsetCorrection))
        }) else {
            return nil
        }

        let newOffset = matchedStart - elapsed
        // Reject implausibly large offsets — usually a chorus-line collision
        // where the AX text matched the wrong repeat.
        guard abs(newOffset) <= 10 else {
            AppTelemetry.performance.info("LRC calibration rejected offset=\(newOffset) line=\"\(matched.text, privacy: .public)\"")
            return nil
        }
        guard abs(newOffset - current.offsetCorrection) > 0.05 else {
            return nil
        }

        return current.withOffsetCorrection(newOffset)
    }

    private static func normalizeForMatch(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func startAXObserverIfNeeded(appState: AppState) {
        guard observedAppState !== appState else { return }
        observedAppState = appState
        axObserver.start { [weak self, weak appState] in
            guard let self, let appState else { return }
            self.performIntegratedVisibleLyricsRefresh(
                appState: appState,
                minimumInterval: Self.observerDrivenCooldown
            )
        }
    }

    func stopHiddenWork(appState: AppState) {
        axObserver.stop()
        observedAppState = nil

        guard loadTask != nil else {
            appState.setProviderRuntimeState(.idle)
            return
        }

        AppTelemetry.performance.info("Provider pipeline mock load cancelled")
        loadTask?.cancel()
        loadTask = nil
        appState.setProviderRuntimeState(.idle)
    }

    private func loadTranslation(for document: LyricsDocument, appState: AppState) async {
        guard appState.showsTranslation else {
            appState.applyProviderReady()
            return
        }

        let translationResult = await translationProvider.translation(
            for: document,
            targetLanguage: appState.preferredTranslationLanguage
        )
        guard !Task.isCancelled else {
            return
        }

        switch translationResult {
        case .available(let translation):
            appState.applyTranslation(translation)
            appState.applyProviderReady()
        case .unavailable:
            appState.clearTranslation()
            appState.applyProviderReady()
        case .failed(let message):
            appState.applyProviderFailure(message)
        }
    }
}
