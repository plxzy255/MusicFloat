import Foundation

struct LyricLine: Equatable, Identifiable, Sendable {
    let id: Int
    let text: String
    let startTime: TimeInterval?
}

enum LyricsSource: String, Equatable, Sendable {
    case mock
    case musicApp
    case lrclib
    case publicProvider
    case none

    var displayName: String {
        switch self {
        case .mock:
            "Mock lyrics"
        case .musicApp:
            "Music app"
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

    var attribution: String {
        source.displayName
    }
}
