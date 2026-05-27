import Foundation

struct LyricsTimingSummary: Equatable, Sendable {
    let source: LyricsSource
    let sourceLanguageIdentifier: String?
    let isTimed: Bool
    let lineCount: Int
    let timedLineCount: Int
    let lineEndCount: Int
    let syllableCount: Int
    let hasWordTiming: Bool
    let hasLineEndTiming: Bool
    let offsetCorrectionMilliseconds: Int
    let effectiveLyricTimeMilliseconds: Int?
    let activeLineID: Int?
    let activeLineIndex: Int?
    let nextLineStartMilliseconds: Int?
    let nextSyllableBoundaryMilliseconds: Int?
    let firstLineStartMilliseconds: Int?
    let lastLineStartMilliseconds: Int?
    let lastLineEndMilliseconds: Int?
    let leadingGapMilliseconds: Int?
    let trailingGapMilliseconds: Int?
    let interlineGapCount: Int
    let longInterlineGapCount: Int
    let maxInterlineGapMilliseconds: Int?
    let overlapCount: Int
    let estimatedUntimedLineDurationMilliseconds: Int?
}

enum LyricsTimingDiagnostics {
    static let longGapThreshold: TimeInterval = 2.0

    static func summary(
        for document: LyricsDocument,
        elapsedTime: TimeInterval,
        duration: TimeInterval?,
        lyricOffsetSeconds: TimeInterval = 0
    ) -> LyricsTimingSummary {
        let effectiveElapsed = finite(elapsedTime + lyricOffsetSeconds)
        let effectiveLyricTime = effectiveElapsed.map { $0 + document.offsetCorrection }.flatMap { finite($0) }
        let timingStats = timingStats(for: document, duration: duration)
        let activeIndex = activeLineIndex(
            in: document,
            effectiveElapsed: effectiveElapsed,
            effectiveLyricTime: effectiveLyricTime,
            duration: duration
        )

        return LyricsTimingSummary(
            source: document.source,
            sourceLanguageIdentifier: document.sourceLanguageIdentifier,
            isTimed: document.isTimed,
            lineCount: document.lines.count,
            timedLineCount: document.lines.reduce(0) { $0 + (finite($1.startTime) == nil ? 0 : 1) },
            lineEndCount: document.lines.reduce(0) { $0 + (finite($1.endTime) == nil ? 0 : 1) },
            syllableCount: document.lines.reduce(0) { $0 + $1.syllables.count },
            hasWordTiming: document.lines.contains { !$0.syllables.isEmpty },
            hasLineEndTiming: document.lines.contains { finite($0.endTime) != nil },
            offsetCorrectionMilliseconds: milliseconds(document.offsetCorrection) ?? 0,
            effectiveLyricTimeMilliseconds: milliseconds(effectiveLyricTime),
            activeLineID: activeIndex.map { document.lines[$0].id },
            activeLineIndex: activeIndex,
            nextLineStartMilliseconds: milliseconds(nextLineStart(in: document, after: effectiveLyricTime)),
            nextSyllableBoundaryMilliseconds: milliseconds(nextSyllableBoundary(in: document, after: effectiveLyricTime)),
            firstLineStartMilliseconds: milliseconds(timingStats.firstLineStart),
            lastLineStartMilliseconds: milliseconds(timingStats.lastLineStart),
            lastLineEndMilliseconds: milliseconds(timingStats.lastLineEnd),
            leadingGapMilliseconds: milliseconds(timingStats.leadingGap),
            trailingGapMilliseconds: milliseconds(timingStats.trailingGap),
            interlineGapCount: timingStats.interlineGapCount,
            longInterlineGapCount: timingStats.longInterlineGapCount,
            maxInterlineGapMilliseconds: milliseconds(timingStats.maxInterlineGap),
            overlapCount: timingStats.overlapCount,
            estimatedUntimedLineDurationMilliseconds: milliseconds(estimatedUntimedLineDuration(
                in: document,
                duration: duration
            ))
        )
    }

    private struct TimingStats {
        var firstLineStart: TimeInterval?
        var lastLineStart: TimeInterval?
        var lastLineEnd: TimeInterval?
        var leadingGap: TimeInterval?
        var trailingGap: TimeInterval?
        var interlineGapCount = 0
        var longInterlineGapCount = 0
        var maxInterlineGap: TimeInterval?
        var overlapCount = 0
    }

    private static func timingStats(for document: LyricsDocument, duration: TimeInterval?) -> TimingStats {
        var stats = TimingStats()
        var previousEnd: TimeInterval?

        for line in document.lines {
            guard let start = finite(line.startTime) else {
                continue
            }
            let end = lineEnd(for: line, fallbackStart: start)

            if stats.firstLineStart == nil {
                stats.firstLineStart = start
                if start > 0 {
                    stats.leadingGap = start
                }
            }

            if let previousEnd {
                let delta = start - previousEnd
                if delta > 0 {
                    stats.interlineGapCount += 1
                    stats.maxInterlineGap = max(stats.maxInterlineGap ?? delta, delta)
                    if delta >= longGapThreshold {
                        stats.longInterlineGapCount += 1
                    }
                } else if delta < 0 {
                    stats.overlapCount += 1
                }
            }

            stats.lastLineStart = start
            stats.lastLineEnd = end
            previousEnd = max(previousEnd ?? end, end)
        }

        if let duration = finite(duration),
           let lastLineEnd = stats.lastLineEnd {
            let trailing = duration - lastLineEnd
            if trailing > 0 {
                stats.trailingGap = trailing
            }
        }

        return stats
    }

    private static func activeLineIndex(
        in document: LyricsDocument,
        effectiveElapsed: TimeInterval?,
        effectiveLyricTime: TimeInterval?,
        duration: TimeInterval?
    ) -> Int? {
        guard !document.lines.isEmpty else {
            return nil
        }

        guard document.isTimed else {
            return estimatedUntimedLineIndex(in: document, elapsedTime: effectiveElapsed, duration: duration)
        }

        guard let effectiveLyricTime else {
            return nil
        }

        return document.lines.lastIndex { line in
            guard let startTime = finite(line.startTime) else {
                return false
            }
            return startTime <= effectiveLyricTime
        }
    }

    private static func estimatedUntimedLineIndex(
        in document: LyricsDocument,
        elapsedTime: TimeInterval?,
        duration: TimeInterval?
    ) -> Int? {
        guard !document.lines.isEmpty else {
            return nil
        }

        guard document.lines.count > 1,
              let duration = finite(duration),
              duration > 0,
              let elapsedTime = finite(elapsedTime) else {
            return 0
        }

        let progress = min(1, max(0, elapsedTime / duration))
        let targetSlot = progress * Double(document.lines.count)
        return min(document.lines.count - 1, max(0, Int(targetSlot.rounded(.down))))
    }

    private static func estimatedUntimedLineDuration(
        in document: LyricsDocument,
        duration: TimeInterval?
    ) -> TimeInterval? {
        guard !document.isTimed,
              document.lines.count > 1,
              let duration = finite(duration),
              duration > 0 else {
            return nil
        }
        return duration / Double(document.lines.count)
    }

    private static func nextLineStart(in document: LyricsDocument, after effectiveLyricTime: TimeInterval?) -> TimeInterval? {
        guard document.isTimed,
              let effectiveLyricTime else {
            return nil
        }

        return document.lines
            .compactMap { finite($0.startTime) }
            .filter { $0 > effectiveLyricTime }
            .min()
    }

    private static func nextSyllableBoundary(
        in document: LyricsDocument,
        after effectiveLyricTime: TimeInterval?
    ) -> TimeInterval? {
        guard document.isTimed,
              let effectiveLyricTime else {
            return nil
        }

        return document.lines
            .flatMap(\.syllables)
            .flatMap { [finite($0.startTime), finite($0.endTime)] }
            .compactMap { $0 }
            .filter { $0 > effectiveLyricTime }
            .min()
    }

    private static func lineEnd(for line: LyricLine, fallbackStart: TimeInterval) -> TimeInterval {
        guard let end = finite(line.endTime),
              end >= fallbackStart else {
            return fallbackStart
        }
        return end
    }

    private static func finite(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else {
            return nil
        }
        return value
    }

    private static func milliseconds(_ value: TimeInterval?) -> Int? {
        guard let value = finite(value) else {
            return nil
        }
        return Int((value * 1_000).rounded())
    }
}
