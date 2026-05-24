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
