import Foundation

struct LyricLine: Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
    let startTime: TimeInterval?
}

enum LyricsSource: String, Equatable, Sendable {
    case mock
    case musicApp
    case musicAppUI
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
