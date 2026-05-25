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
    private var translationTask: Task<Void, Never>?
    private var loadingTrackID: String?
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
        AppTelemetry.measure("ProviderPipelineController.prepareOverlayContent") {
            guard let track = appState.playerState.track else {
                appState.clearTranslation()
                appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                appState.applyProviderUnavailable()
                return
            }
            let requestedTrackID = track.id

            guard loadTask == nil else {
                if loadingTrackID == requestedTrackID {
                    AppTelemetry.performance.notice("Provider pipeline duplicate load ignored trackID=\(requestedTrackID, privacy: .public)")
                }
                return
            }

            AppTelemetry.performance.info("Provider pipeline load started")
            appState.setProviderRuntimeState(.loading)
            appState.setOverlayContentState(.loading)
            cancelTranslationTask(appState: appState)
            loadingTrackID = requestedTrackID

            loadTask = Task { @MainActor [weak self, weak appState, track] in
                await AppTelemetry.measure("ProviderPipelineController.prepareOverlayContent.load") {
                    guard let self, let appState else {
                        return
                    }

                    defer {
                        self.loadingTrackID = nil
                        self.loadTask = nil
                    }

                    let startedAt = Date()
                    let lyricsResult = await self.lyricsProvider.lyrics(for: track)
                    AppTelemetry.performance.notice(
                        "Provider lyrics load finished trackID=\(requestedTrackID, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)"
                    )
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
                        appState.applyProviderReady()
                        appState.clearTranslation()
                        self.startTranslation(
                            for: document,
                            requestedTrackID: requestedTrackID,
                            appState: appState
                        )
                    case .unavailable:
                        appState.clearTranslation()
                        appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                        appState.applyProviderUnavailable()
                    case .failed(let message):
                        appState.clearTranslation()
                        appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for lyrics"))
                        appState.applyProviderFailure(message)
                    }
                }
            }
        }
    }

    /// Cancels any in-flight load and starts a fresh one. Intended for the
    /// "track changed" signal in live mode.
    func refreshOverlayContent(appState: AppState) {
        if let trackID = appState.playerState.track?.id,
           loadTask != nil,
           loadingTrackID == trackID {
            AppTelemetry.performance.notice("Provider refresh skipped; same track already loading trackID=\(trackID, privacy: .public)")
            return
        }
        loadTask?.cancel()
        loadTask = nil
        loadingTrackID = nil
        cancelTranslationTask(appState: appState)
        lastIntegratedVisibleLyricsRefresh = .distantPast
        prepareOverlayContent(appState: appState)
    }

    func refreshTranslation(appState: AppState) {
        cancelTranslationTask(appState: appState)
        appState.clearTranslation()
        guard loadTask == nil else {
            appState.setTranslationRuntimeState(.unavailable(reason: "Translation will wait for current lyrics"))
            return
        }
        guard let requestedTrackID = appState.playerState.track?.id else {
            appState.setTranslationRuntimeState(.unavailable(reason: "No current track"))
            return
        }
        startTranslation(
            for: appState.lyricsDocument,
            requestedTrackID: requestedTrackID,
            appState: appState
        )
    }

    /// Live mode can receive transient empty playerInfo payloads while Music
    /// is paused or changing state. Preserve the current document unless the
    /// playback layer has confirmed a real track identity change.
    func refreshOverlayContentForLiveTrack(appState: AppState) {
        guard appState.playerState.track != nil else {
            cancelInFlightLoadPreservingState(appState: appState)
            AppTelemetry.performance.info("Live provider refresh skipped for empty track payload")
            return
        }
        guard appState.isOverlayVisible || appState.runtimeFeatureFlags.allowsHiddenProviderRefresh else {
            cancelInFlightLoadPreservingState(appState: appState)
            AppTelemetry.performance.info("Live track refresh deferred while overlay hidden")
            return
        }
        refreshOverlayContent(appState: appState)
    }

    func cancelInFlightLoadPreservingState(appState: AppState) {
        guard loadTask != nil || translationTask != nil else { return }
        AppTelemetry.performance.info("Provider pipeline load cancelled because live track payload is empty")
        loadTask?.cancel()
        loadTask = nil
        loadingTrackID = nil
        cancelTranslationTask(appState: appState)
    }

    func refreshIntegratedVisibleLyrics(appState: AppState) {
        guard appState.isOverlayVisible,
              appState.isLiveModeRunning else {
            axObserver.stop()
            observedAppState = nil
            return
        }
        guard appState.providerRuntimeState != .loading else {
            axObserver.stop()
            observedAppState = nil
            return
        }

        let current = appState.lyricsDocument
        if Self.skipsIntegratedVisibleLyricsRefresh(for: current) {
            // Authoritative timed document straight from Apple. Do not
            // overwrite with a lagging AX scrape and do not calibrate —
            // the TTML clock IS ground truth here.
            axObserver.stop()
            observedAppState = nil
            return
        }

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
        guard appState.providerRuntimeState != .loading else {
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastIntegratedVisibleLyricsRefresh) >= minimumInterval else {
            return
        }
        lastIntegratedVisibleLyricsRefresh = now

        let current = appState.lyricsDocument
        if Self.skipsIntegratedVisibleLyricsRefresh(for: current) {
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
        refreshTranslation(appState: appState)
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

    static func skipsIntegratedVisibleLyricsRefresh(for document: LyricsDocument) -> Bool {
        document.source == .appleMusicWeb && document.isTimed
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
        cancelTranslationTask(appState: appState)

        guard loadTask != nil else {
            appState.setProviderRuntimeState(.idle)
            return
        }

        AppTelemetry.performance.info("Provider pipeline mock load cancelled")
        loadTask?.cancel()
        loadTask = nil
        loadingTrackID = nil
        appState.setProviderRuntimeState(.idle)
    }

    private func startTranslation(
        for document: LyricsDocument,
        requestedTrackID: String,
        appState: AppState
    ) {
        guard appState.showsTranslation else {
            appState.setTranslationRuntimeState(.unavailable(reason: "Translation hidden"))
            return
        }
        guard translationTask == nil else { return }

        appState.setTranslationRuntimeState(.checkingAvailability)
        let targetLanguageIdentifier = appState.preferredTranslationLanguageIdentifier
        AppTelemetry.performance.notice(
            "Translation requested trackID=\(requestedTrackID, privacy: .public) target=\(targetLanguageIdentifier, privacy: .public) lines=\(document.lines.count, privacy: .public)"
        )
        translationTask = Task { @MainActor [weak self, weak appState] in
            guard let self, let appState else { return }
            defer {
                self.translationTask = nil
            }

            appState.setTranslationRuntimeState(.translating)
            let translationResult = await self.translationProvider.translation(
                for: document,
                targetLanguageIdentifier: targetLanguageIdentifier
            )
            guard !Task.isCancelled else {
                return
            }
            guard appState.playerState.track?.id == requestedTrackID else {
                AppTelemetry.performance.info("Translation result ignored because live track changed before translation completed")
                return
            }
            guard appState.preferredTranslationLanguageIdentifier == targetLanguageIdentifier else {
                AppTelemetry.performance.info("Translation result ignored because target language changed")
                return
            }

            switch translationResult {
            case .available(let translation):
                let sourceLanguageIdentifier = translation.sourceLanguageIdentifier ?? "unknown"
                AppTelemetry.performance.notice(
                    "Translation ready trackID=\(requestedTrackID, privacy: .public) source=\(sourceLanguageIdentifier, privacy: .public) target=\(translation.targetLanguageIdentifier, privacy: .public) lines=\(translation.lines.count, privacy: .public)"
                )
                appState.applyTranslation(translation)
                appState.setTranslationRuntimeState(.ready)
            case .status(let state):
                AppTelemetry.performance.notice(
                    "Translation unavailable trackID=\(requestedTrackID, privacy: .public) state=\(state.displayName, privacy: .public)"
                )
                appState.clearTranslation()
                appState.setTranslationRuntimeState(state)
            }
        }
    }

    private func cancelTranslationTask(appState: AppState) {
        guard translationTask != nil else { return }
        translationTask?.cancel()
        translationTask = nil
        appState.setTranslationRuntimeState(.unavailable(reason: "Translation cancelled"))
    }
}
