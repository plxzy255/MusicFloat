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

            switch await lyricsProvider.lyrics(for: track) {
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

        switch await translationProvider.translation(
            for: document,
            targetLanguage: appState.preferredTranslationLanguage
        ) {
        case .available(let translation):
            appState.applyTranslation(translation)
            appState.applyProviderReady()
        case .unavailable:
            appState.applyProviderReady()
        case .failed(let message):
            appState.applyProviderFailure(message)
        }
    }
}
