import Foundation

struct LyricsSyncEngine: Sendable {
    func activeLine(in document: LyricsDocument, at elapsedTime: TimeInterval) -> LyricLine? {
        guard !document.lines.isEmpty else {
            return nil
        }

        guard document.isTimed else {
            return document.lines.first
        }

        return document.lines.last { line in
            guard let startTime = line.startTime else {
                return false
            }

            return startTime <= elapsedTime
        }
    }

    func nextLineStart(in document: LyricsDocument, after elapsedTime: TimeInterval) -> TimeInterval? {
        guard document.isTimed else {
            return nil
        }

        return document.lines
            .compactMap(\.startTime)
            .filter { $0 > elapsedTime }
            .min()
    }
}
