import Foundation

struct LyricsSyncEngine: Sendable {
    func activeLine(in document: LyricsDocument, at elapsedTime: TimeInterval) -> LyricLine? {
        guard !document.lines.isEmpty else {
            return nil
        }

        guard document.isTimed else {
            return document.lines.first
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
        guard document.isTimed else {
            return nil
        }

        let effective = elapsedTime + document.offsetCorrection
        return document.lines
            .compactMap(\.startTime)
            .filter { $0 > effective }
            .min()
            .map { $0 - document.offsetCorrection }
    }
}
