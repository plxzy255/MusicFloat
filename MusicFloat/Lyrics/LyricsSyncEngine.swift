import Foundation

struct LyricsSyncEngine: Sendable {
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

        guard document.isTimed else {
            return estimatedUntimedLine(in: document, at: elapsedTime, duration: duration)
        }

        let effective = elapsedTime + document.offsetCorrection
        return document.lines.last { line in
            guard let startTime = line.startTime else {
                return false
            }

            return startTime <= effective
        }
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

    func nextLineEnd(in document: LyricsDocument, after elapsedTime: TimeInterval) -> TimeInterval? {
        guard document.isTimed else {
            return nil
        }

        let effective = elapsedTime + document.offsetCorrection
        return document.lines
            .compactMap(\.endTime)
            .filter { $0 > effective }
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
