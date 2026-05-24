import Foundation

struct LyricSyllable: Equatable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct LyricLine: Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    /// Word/syllable timings when the source carries them (Apple Music TTML).
    /// Populated but not rendered yet — kept so a future karaoke-style
    /// per-syllable overlay can ship without re-fetching.
    let syllables: [LyricSyllable]

    init(
        id: Int,
        text: String,
        startTime: TimeInterval?,
        endTime: TimeInterval? = nil,
        syllables: [LyricSyllable] = []
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.syllables = syllables
    }
}

enum LyricsSource: String, Equatable, Sendable {
    case mock
    case musicApp
    case musicAppUI
    case appleMusicWeb
    case lrclib
    case publicProvider
    case none

    var displayName: String {
        switch self {
        case .mock:
            "Mock lyrics"
        case .musicApp:
            "Music app"
        case .musicAppUI:
            "Music app UI"
        case .appleMusicWeb:
            "Apple Music"
        case .lrclib:
            "LRCLIB"
        case .publicProvider:
            "Public provider"
        case .none:
            "None"
        }
    }
}

struct LyricsDocument: Equatable, Sendable {
    let source: LyricsSource
    let lines: [LyricLine]
    let isTimed: Bool
    /// Seconds to add to player `elapsedTime` before resolving the active line.
    /// Populated by the calibration pass when AX ground-truth disagrees with
    /// the LRC document's clock (e.g. LRCLIB matched a different master).
    let offsetCorrection: TimeInterval

    init(
        source: LyricsSource,
        lines: [LyricLine],
        isTimed: Bool,
        offsetCorrection: TimeInterval = 0
    ) {
        self.source = source
        self.lines = lines
        self.isTimed = isTimed
        self.offsetCorrection = offsetCorrection
    }

    var attribution: String {
        source.displayName
    }

    func withOffsetCorrection(_ offset: TimeInterval) -> LyricsDocument {
        LyricsDocument(
            source: source,
            lines: lines,
            isTimed: isTimed,
            offsetCorrection: offset
        )
    }
}
