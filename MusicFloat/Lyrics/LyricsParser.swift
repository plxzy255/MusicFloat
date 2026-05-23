import Foundation

/// Parses raw lyric text into a `LyricsDocument`.
///
/// Two shapes are supported:
/// - LRC (timed): `[mm:ss.xx] line` repeated, with optional `[offset:+/-ms]`.
/// - Plain: one line per logical lyric line, no timing.
enum LyricsParser {
    /// Returns a timed document if the input parses as LRC. Returns nil if no
    /// LRC timestamps were found.
    static func parseLRC(_ raw: String, source: LyricsSource) -> LyricsDocument? {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard let timestampRegex = try? NSRegularExpression(
            pattern: #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        ) else { return nil }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let offsetSeconds: Double = {
            guard let offsetRegex = try? NSRegularExpression(
                pattern: #"\[offset:\s*([+-]?\d+)\]"#,
                options: [.caseInsensitive]
            ),
            let match = offsetRegex.matches(in: text, range: fullRange).last,
            let range = Range(match.range(at: 1), in: text),
            let ms = Double(text[range]) else {
                return 0
            }
            return ms / 1000.0
        }()

        struct Pending {
            let text: String
            let startTime: TimeInterval
        }
        var pending: [Pending] = []

        for rawLine in text.components(separatedBy: "\n") {
            let ns = rawLine as NSString
            let matches = timestampRegex.matches(
                in: rawLine,
                range: NSRange(location: 0, length: ns.length)
            )
            guard !matches.isEmpty else { continue }

            let lyricText = timestampRegex.stringByReplacingMatches(
                in: rawLine,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyricText.isEmpty else { continue }

            for match in matches {
                let minutes = Double(ns.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: match.range(at: 2))) ?? 0
                var fractional: Double = 0
                if match.range(at: 3).location != NSNotFound {
                    let fracString = ns.substring(with: match.range(at: 3))
                    if !fracString.isEmpty {
                        fractional = (Double(fracString) ?? 0) / pow(10, Double(fracString.count))
                    }
                }
                let startTime = (minutes * 60) + seconds + fractional + offsetSeconds
                pending.append(Pending(text: lyricText, startTime: startTime))
            }
        }

        guard !pending.isEmpty else { return nil }
        let sorted = pending.sorted { $0.startTime < $1.startTime }
        let lines = sorted.enumerated().map { offset, entry in
            LyricLine(id: offset, text: entry.text, startTime: entry.startTime)
        }
        return LyricsDocument(source: source, lines: lines, isTimed: true)
    }

    /// Returns an untimed document from a plain newline-separated string.
    /// Returns nil if no usable lines remain after trimming.
    static func parsePlain(_ raw: String, source: LyricsSource) -> LyricsDocument? {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { offset, text in LyricLine(id: offset, text: text, startTime: nil) }

        guard !lines.isEmpty else { return nil }
        return LyricsDocument(source: source, lines: lines, isTimed: false)
    }

    /// Convenience: prefer LRC, fall back to plain.
    static func parse(synced: String?, plain: String?, source: LyricsSource) -> LyricsDocument? {
        if let synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let doc = parseLRC(synced, source: source) {
            return doc
        }
        if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let doc = parsePlain(plain, source: source) {
            return doc
        }
        return nil
    }
}
