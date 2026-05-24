import Foundation
import NaturalLanguage

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
    let sourceLanguageIdentifier: String?
    /// Seconds to add to player `elapsedTime` before resolving the active line.
    /// Populated by the calibration pass when AX ground-truth disagrees with
    /// the LRC document's clock (e.g. LRCLIB matched a different master).
    let offsetCorrection: TimeInterval

    init(
        source: LyricsSource,
        lines: [LyricLine],
        isTimed: Bool,
        sourceLanguageIdentifier: String? = nil,
        offsetCorrection: TimeInterval = 0
    ) {
        self.source = source
        self.lines = lines
        self.isTimed = isTimed
        self.sourceLanguageIdentifier = Self.normalizedLanguageIdentifier(sourceLanguageIdentifier)
            ?? Self.inferredSourceLanguageIdentifier(from: lines)
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
            sourceLanguageIdentifier: sourceLanguageIdentifier,
            offsetCorrection: offset
        )
    }

    static func inferredSourceLanguageIdentifier(from lines: [LyricLine]) -> String? {
        let text = lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 20 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first,
              confidence >= 0.35,
              language != .undetermined else {
            return nil
        }

        return normalizedLanguageIdentifier(language.rawValue)
    }

    static func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        return Locale.Language(identifier: normalized).minimalIdentifier
    }
}
