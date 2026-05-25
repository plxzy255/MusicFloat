import OSLog
import SwiftUI
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

struct LyricsOverlayView: View {
    @Bindable var appState: AppState
    var onTranslationPreparationCompleted: () -> Void = {}
    #if ENABLE_APPLE_TRANSLATION
    @State private var preparationConfiguration: TranslationSession.Configuration?
    @State private var activePreparationIdentifier: String?
    @State private var preparedTranslationIdentifiers: Set<String> = []
    #endif

    var body: some View {
        #if ENABLE_APPLE_TRANSLATION
        content
            .translationTask(preparationConfiguration) { session in
                await prepareTranslationLanguages(with: session)
            }
            .task(id: translationPreparationRequestIdentifier) {
                scheduleTranslationPreparationIfNeeded()
            }
        #else
        content
        #endif
    }

    private var content: some View {
        let snapshot = appState.overlaySnapshot

        return ZStack {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(snapshot.contentState.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateTint(for: snapshot.contentState))
                        .lineLimit(1)

                    Text(snapshot.statusText)
                        .lineLimit(1)

                    Text(snapshot.attributionText)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(snapshot.trackText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                lyricText(for: snapshot)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)

                if let translationText = snapshot.translationText {
                    Text(translationText)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(width: CGFloat(snapshot.widthPreset.width), height: 172, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: CGFloat(snapshot.widthPreset.width), height: 172)
        .contentShape(Rectangle())
        .onAppear {
            AppTelemetry.windowing.info("Lyrics overlay view appeared")
            #if ENABLE_APPLE_TRANSLATION
            scheduleTranslationPreparationIfNeeded()
            #endif
        }
        .onDisappear {
            AppTelemetry.windowing.info("Lyrics overlay view disappeared")
        }
    }

    #if ENABLE_APPLE_TRANSLATION
    private var translationPreparationRequestIdentifier: String? {
        guard let download = appState.pendingTranslationDownload else { return nil }
        return "\(download.source)->\(download.target)"
    }

    private func scheduleTranslationPreparationIfNeeded() {
        guard let download = appState.pendingTranslationDownload else { return }
        let identifier = "\(download.source)->\(download.target)"
        guard activePreparationIdentifier != identifier else { return }
        guard !preparedTranslationIdentifiers.contains(identifier) else { return }

        activePreparationIdentifier = identifier
        preparationConfiguration = TranslationSession.Configuration(
            source: Locale.Language(identifier: download.source),
            target: Locale.Language(identifier: download.target),
            preferredStrategy: .lowLatency
        )
        AppTelemetry.windowing.notice(
            "Overlay translation preparation requested source=\(download.source, privacy: .public) target=\(download.target, privacy: .public)"
        )
    }

    private func prepareTranslationLanguages(with session: TranslationSession) async {
        let document = appState.lyricsDocument
        let targetLanguageIdentifier = appState.preferredTranslationLanguageIdentifier
        let activeTrackID = appState.playerState.track?.id

        do {
            try await session.prepareTranslation()
            if let activePreparationIdentifier {
                preparedTranslationIdentifiers.insert(activePreparationIdentifier)
            }
            preparationConfiguration = nil
            activePreparationIdentifier = nil
            AppTelemetry.windowing.notice("Overlay translation preparation completed")

            appState.setTranslationRuntimeState(.translating)
            if let translation = try await PreparedTranslationSessionTranslator.translation(
                using: session,
                for: document,
                targetLanguageIdentifier: targetLanguageIdentifier
            ) {
                guard appState.playerState.track?.id == activeTrackID,
                      appState.lyricsDocument.hasSameTranslationContent(as: document),
                      appState.preferredTranslationLanguageIdentifier == targetLanguageIdentifier else {
                    AppTelemetry.windowing.notice("Prepared translation ignored because live context changed")
                    appState.setTranslationRuntimeState(.idle)
                    onTranslationPreparationCompleted()
                    return
                }
                appState.applyTranslation(translation)
                appState.setTranslationRuntimeState(.ready)
                AppTelemetry.windowing.notice(
                    "Prepared translation ready source=\(translation.sourceLanguageIdentifier ?? "unknown", privacy: .public) target=\(translation.targetLanguageIdentifier, privacy: .public) lines=\(translation.lines.count, privacy: .public)"
                )
                return
            }

            appState.setTranslationRuntimeState(.idle)
            onTranslationPreparationCompleted()
        } catch is CancellationError {
            preparationConfiguration = nil
            activePreparationIdentifier = nil
            appState.setTranslationRuntimeState(.idle)
            AppTelemetry.windowing.info("Overlay translation preparation cancelled")
        } catch {
            preparationConfiguration = nil
            activePreparationIdentifier = nil
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = detail.isEmpty ? "Translation preparation failed" : "Translation preparation failed: \(detail)"
            appState.setTranslationRuntimeState(.failed(reason))
            AppTelemetry.windowing.error("Overlay translation preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif

    private func stateTint(for state: OverlayContentState) -> Color {
        switch state {
        case .loading:
            .blue
        case .ready:
            .green
        case .unavailable:
            .secondary
        case .failed:
            .red
        }
    }

    private func lyricText(for snapshot: LyricsOverlaySnapshot) -> Text {
        guard let activeLine = snapshot.activeLine, !activeLine.syllables.isEmpty else {
            return Text(snapshot.lyricText)
                .foregroundStyle(.primary)
        }

        let activeIndex = LyricsOverlaySnapshotBuilder.activeSyllableIndex(
            in: activeLine,
            at: snapshot.effectiveLyricTime
        )

        return Text(styledSyllables(activeLine.syllables, activeIndex: activeIndex))
    }

    private func styledSyllables(
        _ syllables: [LyricSyllable],
        activeIndex: Int?
    ) -> AttributedString {
        var text = AttributedString()

        for index in syllables.indices {
            var segment = AttributedString(syllables[index].text)

            guard let activeIndex else {
                segment.foregroundColor = .secondary
                text += segment
                continue
            }

            if index < activeIndex {
                segment.foregroundColor = .primary.opacity(0.62)
            } else if index == activeIndex {
                segment.foregroundColor = .primary
                segment.inlinePresentationIntent = .stronglyEmphasized
            } else {
                segment.foregroundColor = .secondary
            }

            text += segment
        }

        return text
    }
}

#Preview {
    LyricsOverlayView(appState: AppState())
        .padding()
}
