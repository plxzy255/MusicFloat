import Foundation

struct LyricsTimelinePosition: Equatable, Sendable {
    let activeLine: LyricLine?
    let previousLine: LyricLine?
    let nextLine: LyricLine?
    let isInterlude: Bool

    static let empty = LyricsTimelinePosition(
        activeLine: nil,
        previousLine: nil,
        nextLine: nil,
        isInterlude: false
    )
}

struct LyricsSyncEngine: Sendable {
    private static let lineEndGrace: TimeInterval = 0.25
    private static let interludeMinimumGap: TimeInterval = 3.0

    func activeLine(in document: LyricsDocument, at elapsedTime: TimeInterval) -> LyricLine? {
        activeLine(in: document, at: elapsedTime, duration: nil)
    }

    func activeLine(
        in document: LyricsDocument,
        at elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> LyricLine? {
        guard !document.lines.isEmpty else {
            return nil
        }

        return timelinePosition(in: document, at: elapsedTime, duration: duration).activeLine
    }

    func nextLineStart(in document: LyricsDocument, after elapsedTime: TimeInterval) -> TimeInterval? {
        nextLineStart(in: document, after: elapsedTime, duration: nil)
    }

    func nextLineStart(
        in document: LyricsDocument,
        after elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval? {
        guard document.isTimed else {
            return nextEstimatedUntimedLineStart(in: document, after: elapsedTime, duration: duration)
        }

        let effective = elapsedTime + document.offsetCorrection
        return document.lines
            .compactMap(\.startTime)
            .filter { $0 > effective }
            .min()
            .map { $0 - document.offsetCorrection }
    }

    func nextDisplayBoundary(in document: LyricsDocument, after elapsedTime: TimeInterval) -> TimeInterval? {
        nextDisplayBoundary(in: document, after: elapsedTime, duration: nil)
    }

    func nextDisplayBoundary(
        in document: LyricsDocument,
        after elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval? {
        guard document.isTimed else {
            return nextEstimatedUntimedLineStart(in: document, after: elapsedTime, duration: duration)
        }

        let effective = elapsedTime + document.offsetCorrection
        return timedIntervals(in: document.lines)
            .flatMap { interval -> [TimeInterval] in
                var boundaries: [TimeInterval] = []
                if interval.activationTime > effective {
                    boundaries.append(interval.activationTime)
                }
                if interval.interludeStart > effective,
                   interval.interludeStart < interval.deactivationTime {
                    boundaries.append(interval.interludeStart)
                }
                return boundaries
            }
            .min()
            .map { $0 - document.offsetCorrection }
    }

    func nextSyllableBoundary(in document: LyricsDocument, after elapsedTime: TimeInterval) -> TimeInterval? {
        guard document.isTimed else {
            return nil
        }

        let effective = elapsedTime + document.offsetCorrection
        return document.lines
            .flatMap(\.syllables)
            .flatMap { syllable in
                [syllable.startTime, syllable.endTime]
            }
            .filter { $0 > effective }
            .min()
            .map { $0 - document.offsetCorrection }
    }

    func timelinePosition(
        in document: LyricsDocument,
        at elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> LyricsTimelinePosition {
        guard !document.lines.isEmpty else {
            return .empty
        }

        guard document.isTimed else {
            return untimedTimelinePosition(in: document, at: elapsedTime, duration: duration)
        }

        let effective = elapsedTime + document.offsetCorrection
        let intervals = timedIntervals(in: document.lines)
        guard !intervals.isEmpty else {
            return .empty
        }

        if let active = intervals.last(where: { interval in
            interval.activationTime <= effective && effective < interval.interludeStart
        }) {
            return LyricsTimelinePosition(
                activeLine: active.line,
                previousLine: active.previousLine,
                nextLine: active.nextLine,
                isInterlude: false
            )
        }

        if let interlude = intervals.last(where: { interval in
            interval.interludeStart <= effective && effective < interval.deactivationTime
        }) {
            return LyricsTimelinePosition(
                activeLine: nil,
                previousLine: interlude.line,
                nextLine: interlude.nextLine,
                isInterlude: true
            )
        }

        if let next = intervals.first(where: { $0.activationTime > effective }) {
            if next.previousLine == nil,
               next.activationTime >= Self.interludeMinimumGap {
                return LyricsTimelinePosition(
                    activeLine: nil,
                    previousLine: nil,
                    nextLine: next.line,
                    isInterlude: true
                )
            }

            return LyricsTimelinePosition(
                activeLine: nil,
                previousLine: nil,
                nextLine: next.line,
                isInterlude: false
            )
        }

        return .empty
    }

    private func untimedTimelinePosition(
        in document: LyricsDocument,
        at elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> LyricsTimelinePosition {
        guard let activeLine = estimatedUntimedLine(in: document, at: elapsedTime, duration: duration),
              let activeIndex = document.lines.firstIndex(where: { $0.id == activeLine.id }) else {
            return .empty
        }

        return LyricsTimelinePosition(
            activeLine: activeLine,
            previousLine: activeIndex > 0 ? document.lines[activeIndex - 1] : nil,
            nextLine: activeIndex + 1 < document.lines.count ? document.lines[activeIndex + 1] : nil,
            isInterlude: false
        )
    }

    private struct TimedLineInterval {
        let line: LyricLine
        let previousLine: LyricLine?
        let nextLine: LyricLine?
        let activationTime: TimeInterval
        let interludeStart: TimeInterval
        let deactivationTime: TimeInterval
    }

    private func timedIntervals(in lines: [LyricLine]) -> [TimedLineInterval] {
        let timedLines = lines.enumerated().compactMap { index, line -> (index: Int, line: LyricLine, start: TimeInterval)? in
            guard let start = line.startTime else {
                return nil
            }
            return (index, line, start)
        }

        return timedLines.enumerated().map { position, entry in
            let previous = position > 0 ? timedLines[position - 1] : nil
            let next = position + 1 < timedLines.count ? timedLines[position + 1] : nil
            let previousEnd = previous?.line.endTime
            let activationTime = max(entry.start, previousEnd ?? entry.start)
            let nextActivationTime = next.map { nextEntry in
                max(nextEntry.start, entry.line.endTime ?? nextEntry.start)
            } ?? .infinity

            let rawEnd = next == nil ? .infinity : entry.line.endTime ?? nextActivationTime
            let boundedEnd = min(max(rawEnd, activationTime), nextActivationTime)
            let interludeStart = interludeStartTime(
                lineEnd: entry.line.endTime,
                nextActivationTime: nextActivationTime,
                fallbackEnd: boundedEnd
            )

            return TimedLineInterval(
                line: entry.line,
                previousLine: previous?.line,
                nextLine: next?.line,
                activationTime: activationTime,
                interludeStart: interludeStart,
                deactivationTime: nextActivationTime
            )
        }
    }

    private func interludeStartTime(
        lineEnd: TimeInterval?,
        nextActivationTime: TimeInterval,
        fallbackEnd: TimeInterval
    ) -> TimeInterval {
        guard let lineEnd,
              nextActivationTime.isFinite,
              nextActivationTime - lineEnd >= Self.interludeMinimumGap else {
            return fallbackEnd
        }

        return min(lineEnd + Self.lineEndGrace, nextActivationTime)
    }

    private func estimatedUntimedLine(
        in document: LyricsDocument,
        at elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> LyricLine? {
        guard document.lines.count > 1,
              let duration,
              duration.isFinite,
              duration > 0,
              elapsedTime.isFinite else {
            return document.lines.first
        }

        let targetSlot = clampedProgress(elapsedTime / duration) * Double(document.lines.count)
        let index = min(
            document.lines.count - 1,
            max(0, Int(targetSlot.rounded(.down)))
        )
        return document.lines[index]
    }

    private func nextEstimatedUntimedLineStart(
        in document: LyricsDocument,
        after elapsedTime: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval? {
        guard document.lines.count > 1,
              let duration,
              duration.isFinite,
              duration > 0,
              elapsedTime.isFinite,
              elapsedTime < duration else {
            return nil
        }

        let lineDuration = duration / Double(document.lines.count)
        let nextSlot = Int((max(0, elapsedTime) / lineDuration).rounded(.down)) + 1
        guard nextSlot <= document.lines.count else {
            return nil
        }
        return min(duration, Double(nextSlot) * lineDuration)
    }

    private func clampedProgress(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
