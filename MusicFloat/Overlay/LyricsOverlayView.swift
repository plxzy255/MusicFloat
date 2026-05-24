import OSLog
import SwiftUI

struct LyricsOverlayView: View {
    @Bindable var appState: AppState

    var body: some View {
        let snapshot = appState.overlaySnapshot

        ZStack {
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
        }
        .onDisappear {
            AppTelemetry.windowing.info("Lyrics overlay view disappeared")
        }
    }

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

        return activeLine.syllables.indices.reduce(Text("")) { text, index in
            text + styledSyllable(activeLine.syllables[index], index: index, activeIndex: activeIndex)
        }
    }

    private func styledSyllable(
        _ syllable: LyricSyllable,
        index: Int,
        activeIndex: Int?
    ) -> Text {
        guard let activeIndex else {
            return Text(syllable.text)
                .foregroundStyle(.secondary)
        }

        if index < activeIndex {
            return Text(syllable.text)
                .foregroundStyle(.primary.opacity(0.62))
        }

        if index == activeIndex {
            return Text(syllable.text)
                .foregroundStyle(.primary)
                .bold()
        }

        return Text(syllable.text)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    LyricsOverlayView(appState: AppState())
        .padding()
}
