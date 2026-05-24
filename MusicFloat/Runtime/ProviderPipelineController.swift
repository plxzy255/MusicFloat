import Foundation
import OSLog

@MainActor
final class ProviderPipelineController {
    private let lyricsProvider: any LyricsProvider
    private let translationProvider: any TranslationProvider
    private var loadTask: Task<Void, Never>?

    init(
        lyricsProvider: any LyricsProvider = MockLyricsProvider(),
        translationProvider: any TranslationProvider = MockTranslationProvider()
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

            let lyricsResult = await lyricsProvider.lyrics(for: track)
            guard !Task.isCancelled else {
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

    func stopHiddenWork(appState: AppState) {
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
