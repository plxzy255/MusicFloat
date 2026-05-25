import AppKit
import OSLog
import SwiftUI
#if ENABLE_APPLE_TRANSLATION
@preconcurrency @unsafe import Translation
#endif

enum LyricsOverlayLayout {
    static let panelHeight: CGFloat = 248
    static let albumCoverSize: CGFloat = 96
}

@MainActor
struct LyricsOverlayPlaybackCommands {
    var playPause: () -> Void
    var previousTrack: () -> Void
    var nextTrack: () -> Void
    var setVolume: (Int) -> Void
    var seek: (TimeInterval) -> Void

    static let disabled = LyricsOverlayPlaybackCommands(
        playPause: {},
        previousTrack: {},
        nextTrack: {},
        setVolume: { _ in },
        seek: { _ in }
    )
}

struct LyricsOverlayView: View {
    @Bindable var appState: AppState
    var onTranslationPreparationCompleted: () -> Void = {}
    var playbackCommands: LyricsOverlayPlaybackCommands = .disabled
    @State private var showsVolumeSlider = false
    @State private var draftVolume = 50.0
    @State private var isScrubbingPlayback = false
    @State private var draftPlaybackPosition = 0.0
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
            overlayContent(for: snapshot)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(width: CGFloat(snapshot.widthPreset.width), height: LyricsOverlayLayout.panelHeight, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: CGFloat(snapshot.widthPreset.width), height: LyricsOverlayLayout.panelHeight)
        .contentShape(Rectangle())
        .onAppear {
            AppTelemetry.windowing.info("Lyrics overlay view appeared")
            syncDraftVolume()
            #if ENABLE_APPLE_TRANSLATION
            scheduleTranslationPreparationIfNeeded()
            #endif
        }
        .onDisappear {
            AppTelemetry.windowing.info("Lyrics overlay view disappeared")
        }
        .onChange(of: appState.musicVolume) {
            syncDraftVolume()
        }
        .onChange(of: appState.playerState.track?.id) {
            resetDraftPlaybackPosition()
        }
    }

    @ViewBuilder
    private func overlayContent(for snapshot: LyricsOverlaySnapshot) -> some View {
        if appState.isLiveModeRunning {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    albumCoverView(artwork: appState.nowPlayingArtwork)

                    VStack(alignment: .leading, spacing: 7) {
                        Text(snapshot.trackText)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        playbackSliderRow
                        playbackControlsRow
                    }
                    .frame(height: LyricsOverlayLayout.albumCoverSize, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: LyricsOverlayLayout.albumCoverSize, alignment: .top)

                lyricBlock(for: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(alignment: .center, spacing: 14) {
                if appState.nowPlayingArtwork != nil {
                    albumCoverView(artwork: appState.nowPlayingArtwork)
                }

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

                    lyricBlock(for: snapshot)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func lyricBlock(for snapshot: LyricsOverlaySnapshot) -> some View {
        LyricsLineStackView(snapshot: snapshot)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
    }

    @ViewBuilder
    private func albumCoverView(artwork: NSImage?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: LyricsOverlayLayout.albumCoverSize, height: LyricsOverlayLayout.albumCoverSize)
        .clipShape(shape)
        .overlay {
            shape.stroke(.separator.opacity(0.4), lineWidth: 1)
        }
        .accessibilityLabel(artwork == nil ? "Album artwork unavailable" : "Album artwork")
    }

    private var playbackControlsRow: some View {
        HStack(spacing: 7) {
            playbackButton(
                systemName: "backward.fill",
                label: "Previous track",
                help: "Previous track",
                action: playbackCommands.previousTrack
            )

            playbackButton(
                systemName: appState.playerState.playbackStatus == .playing ? "pause.fill" : "play.fill",
                label: appState.playerState.playbackStatus == .playing ? "Pause" : "Play",
                help: appState.playerState.playbackStatus == .playing ? "Pause Apple Music" : "Play Apple Music",
                action: playbackCommands.playPause
            )

            playbackButton(
                systemName: "forward.fill",
                label: "Next track",
                help: "Next track",
                action: playbackCommands.nextTrack
            )

            playbackButton(
                systemName: volumeSystemImageName,
                label: "Volume",
                help: showsVolumeSlider ? "Hide volume" : "Show volume",
                action: toggleVolumeSlider
            )

            if showsVolumeSlider {
                Slider(
                    value: $draftVolume,
                    in: 0...100,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            commitVolumeChange()
                        }
                    }
                )
                .frame(width: volumeSliderWidth)
                .controlSize(.small)
                .disabled(!playbackControlsEnabled)
                .accessibilityLabel("Apple Music volume")

                Text("\(MusicPlaybackCommand.clampedVolume(Int(draftVolume.rounded())))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
        }
        .frame(height: 26, alignment: .leading)
    }

    private var playbackSliderRow: some View {
        let duration = playbackDuration
        return HStack(spacing: 8) {
            Text(formattedPlaybackTime(currentPlaybackPosition))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)

            Slider(
                value: playbackPositionBinding(duration: duration),
                in: 0...max(1, duration),
                onEditingChanged: playbackScrubEditingChanged
            )
            .controlSize(.small)
            .disabled(!playbackControlsEnabled || duration <= 0)
            .accessibilityLabel("Playback position")

            Text(formattedPlaybackTime(duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 20, alignment: .leading)
    }

    private func playbackButton(
        systemName: String,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(playbackControlsEnabled ? .primary : .secondary)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(playbackControlsEnabled ? 1 : 0.55)
        .disabled(!playbackControlsEnabled)
        .help(help)
        .accessibilityLabel(label)
    }

    private var playbackControlsEnabled: Bool {
        appState.isLiveModeRunning && !appState.isPlaybackCommandInFlight
    }

    private var playbackDuration: TimeInterval {
        max(0, appState.playerState.track?.duration ?? 0)
    }

    private var currentPlaybackPosition: TimeInterval {
        let duration = playbackDuration
        let current = isScrubbingPlayback ? draftPlaybackPosition : appState.effectiveElapsedTime
        return MusicPlaybackCommand.clampedPlaybackPosition(current, duration: duration)
    }

    private func playbackPositionBinding(duration: TimeInterval) -> Binding<Double> {
        Binding(
            get: {
                currentPlaybackPosition
            },
            set: { nextValue in
                isScrubbingPlayback = true
                draftPlaybackPosition = MusicPlaybackCommand.clampedPlaybackPosition(nextValue, duration: duration)
            }
        )
    }

    private func playbackScrubEditingChanged(_ isEditing: Bool) {
        if isEditing {
            draftPlaybackPosition = currentPlaybackPosition
            isScrubbingPlayback = true
            return
        }

        let position = MusicPlaybackCommand.clampedPlaybackPosition(
            draftPlaybackPosition,
            duration: playbackDuration
        )
        draftPlaybackPosition = position
        isScrubbingPlayback = false
        playbackCommands.seek(position)
    }

    private var volumeSystemImageName: String {
        let volume = appState.musicVolume ?? MusicPlaybackCommand.clampedVolume(Int(draftVolume.rounded()))
        return volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    private var volumeSliderWidth: CGFloat {
        appState.overlayWidthPreset == .compact ? 84 : 116
    }

    private func toggleVolumeSlider() {
        syncDraftVolume()
        showsVolumeSlider.toggle()
    }

    private func syncDraftVolume() {
        guard let volume = appState.musicVolume else { return }
        draftVolume = Double(MusicPlaybackCommand.clampedVolume(volume))
    }

    private func commitVolumeChange() {
        let volume = MusicPlaybackCommand.clampedVolume(Int(draftVolume.rounded()))
        draftVolume = Double(volume)
        playbackCommands.setVolume(volume)
    }

    private func resetDraftPlaybackPosition() {
        draftPlaybackPosition = MusicPlaybackCommand.clampedPlaybackPosition(
            appState.effectiveElapsedTime,
            duration: playbackDuration
        )
        isScrubbingPlayback = false
    }

    private func formattedPlaybackTime(_ rawSeconds: TimeInterval) -> String {
        guard rawSeconds.isFinite, rawSeconds >= 0 else {
            return "0:00"
        }

        let totalSeconds = Int(rawSeconds.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
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

}

private struct LyricsLineStackView: View {
    let snapshot: LyricsOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if snapshot.lyricWindow.isEmpty {
                LyricsFallbackLineView(snapshot: snapshot)
            } else {
                ForEach(snapshot.lyricWindow) { row in
                    LyricsOverlayLineRowView(
                        row: row,
                        effectiveLyricTime: snapshot.effectiveLyricTime,
                        lyricClockReferenceDate: snapshot.lyricClockReferenceDate,
                        isLyricClockRunning: snapshot.isLyricClockRunning
                    )
                        .id(row.id)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: snapshot.lyricWindow.map(\.id))
    }
}

private struct LyricsFallbackLineView: View {
    let snapshot: LyricsOverlaySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.lyricText)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)

            if let translationText = snapshot.translationText {
                Text(translationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LyricsOverlayLineRowView: View {
    let row: LyricsOverlayLine
    let effectiveLyricTime: TimeInterval
    let lyricClockReferenceDate: Date
    let isLyricClockRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TimedLyricTextView(
                line: row.line,
                role: row.role,
                effectiveLyricTime: effectiveLyricTime,
                lyricClockReferenceDate: lyricClockReferenceDate,
                isLyricClockRunning: isLyricClockRunning
            )

            if let translationText = row.translationText {
                Text(translationText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.role.opacity)
        .accessibilityAddTraits(row.role == .active ? .isSelected : [])
    }
}

private struct TimedLyricTextView: View {
    let line: LyricLine
    let role: LyricsOverlayLineRole
    let effectiveLyricTime: TimeInterval
    let lyricClockReferenceDate: Date
    let isLyricClockRunning: Bool

    var body: some View {
        if role == .active,
           usesSyllableTiming,
           isLyricClockRunning {
            TimelineView(.animation) { context in
                timedText(at: effectiveLyricTime(at: context.date))
            }
        } else {
            timedText(at: effectiveLyricTime)
        }
    }

    @ViewBuilder
    private func timedText(at effectiveLyricTime: TimeInterval) -> some View {
        if let progress = progress(at: effectiveLyricTime),
           role == .active {
            progressText(progress: progress)
        } else {
            plainText
        }
    }

    private func effectiveLyricTime(at date: Date) -> TimeInterval {
        self.effectiveLyricTime + max(0, date.timeIntervalSince(lyricClockReferenceDate))
    }

    private func progress(at effectiveLyricTime: TimeInterval) -> Double? {
        guard usesSyllableTiming else { return nil }
        return LyricsOverlaySnapshotBuilder.timedLineProgress(
            in: line,
            at: effectiveLyricTime
        )
    }

    private var usesSyllableTiming: Bool {
        LyricsOverlaySnapshotBuilder.shouldRenderKaraokeProgress(for: line)
    }

    private var plainText: some View {
        Text(line.text)
            .font(role.lyricFont)
            .foregroundStyle(role == .active ? .primary : .secondary)
            .lineLimit(role == .active ? 2 : 1)
            .minimumScaleFactor(role == .active ? 0.78 : 0.86)
            .contentTransition(.opacity)
    }

    private func progressText(progress: Double) -> some View {
        plainText
            .foregroundStyle(.secondary.opacity(0.62))
            .overlay(alignment: fillAlignment) {
                GeometryReader { proxy in
                    plainText
                        .foregroundStyle(.primary)
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.height,
                            alignment: fillAlignment
                        )
                        .mask(alignment: fillAlignment) {
                            Rectangle()
                                .frame(width: max(1, proxy.size.width * CGFloat(progress)))
                        }
                }
                .allowsHitTesting(false)
            }
    }

    private var fillAlignment: Alignment {
        line.text.prefersRightToLeftLyricFill ? .trailing : .leading
    }
}

private extension LyricsOverlayLineRole {
    var lyricFont: Font {
        switch self {
        case .previous, .next:
            .system(.callout, weight: .medium)
        case .active:
            .system(.title3, weight: .semibold)
        }
    }

    var opacity: Double {
        switch self {
        case .previous, .next:
            0.54
        case .active:
            1
        }
    }
}

private extension String {
    var prefersRightToLeftLyricFill: Bool {
        unicodeScalars.first(where: { scalar in
            CharacterSet.letters.contains(scalar)
        })?.isRightToLeftLyricScalar == true
    }
}

private extension UnicodeScalar {
    var isRightToLeftLyricScalar: Bool {
        switch value {
        case 0x0590...0x05FF, // Hebrew
             0x0600...0x06FF, // Arabic
             0x0750...0x077F, // Arabic Supplement
             0x08A0...0x08FF, // Arabic Extended-A
             0xFB50...0xFDFF, // Arabic Presentation Forms-A
             0xFE70...0xFEFF: // Arabic Presentation Forms-B
            return true
        default:
            return false
        }
    }
}

#Preview {
    LyricsOverlayView(appState: AppState())
        .padding()
}
