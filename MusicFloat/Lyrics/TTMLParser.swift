import Foundation

/// Parses Apple Music TTML lyric payloads into a `LyricsDocument`.
///
/// Apple's TTML carries line timing in `<p begin end>` and (when
/// `itunes:timing="Word"`) syllable timing in nested `<span begin end>` tags.
/// We capture both — line timings drive the existing sync engine; syllables
/// are stored for a future per-word overlay without forcing a re-fetch.
///
/// Time values come in any of: `HH:MM:SS.mmm`, `MM:SS.mmm`, `SS.mmm`, `Ns`.
enum TTMLParser {
    static func parse(ttml: String, source: LyricsSource = .appleMusicWeb) -> LyricsDocument? {
        AppTelemetry.measure("TTMLParser.parse") {
            parseImpl(ttml: ttml, source: source)
        }
    }

    private static func parseImpl(ttml: String, source: LyricsSource) -> LyricsDocument? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.lines.isEmpty else {
            return nil
        }
        let isTimed = delegate.lines.contains { $0.startTime != nil }
        return LyricsDocument(source: source, lines: delegate.lines, isTimed: isTimed)
    }

    static func parseTimecode(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("s") {
            return Double(trimmed.dropLast())
        }
        let parts = trimmed.split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return nil
        }
    }

    static func languageTag(in ttml: String) -> String? {
        guard let data = ttml.data(using: .utf8) else { return nil }
        let delegate = LanguageDelegate()
        let parser = XMLParser(data: data)
        unsafe parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return delegate.language
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []

        private var inP = false
        private var pBegin: TimeInterval?
        private var pEnd: TimeInterval?
        private var pSpans: [LyricSyllable] = []
        private var pText: String = ""
        private var spanBegin: TimeInterval?
        private var spanEnd: TimeInterval?
        private var spanText: String = ""
        private var inSpan = false
        private var nextID = 0

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let name = localName(elementName)
            switch name {
            case "p":
                inP = true
                pBegin = TTMLParser.parseTimecode(attributeDict["begin"])
                pEnd = TTMLParser.parseTimecode(attributeDict["end"])
                pSpans.removeAll()
                pText = ""
            case "span":
                guard inP else { return }
                inSpan = true
                spanBegin = TTMLParser.parseTimecode(attributeDict["begin"])
                spanEnd = TTMLParser.parseTimecode(attributeDict["end"])
                spanText = ""
            case "br":
                // Apple uses <br/> for in-line breaks within a paragraph.
                // Preserve as a space so words don't run together.
                if inSpan { spanText += " " } else if inP { pText += " " }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSpan {
                spanText += string
            } else if inP {
                pText += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName)
            switch name {
            case "span":
                guard inSpan else { return }
                let text = spanText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, let begin = spanBegin, let end = spanEnd {
                    pSpans.append(LyricSyllable(text: spanText, startTime: begin, endTime: end))
                }
                // Spans inside <p> together form the line text. Keep a
                // raw reconstruction so syllable fragments can join without
                // invented spaces while source-provided spacing is preserved.
                if !pSpans.isEmpty || pText.isEmpty {
                    if pText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        pText = ""
                    }
                    pText += spanText
                }
                inSpan = false
                spanBegin = nil
                spanEnd = nil
                spanText = ""
            case "p":
                let cleaned = pText
                    .replacingOccurrences(of: "  ", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    lines.append(LyricLine(
                        id: nextID,
                        text: cleaned,
                        startTime: pBegin,
                        endTime: pEnd,
                        syllables: pSpans
                    ))
                    nextID += 1
                }
                inP = false
                pBegin = nil
                pEnd = nil
                pSpans.removeAll()
                pText = ""
            default:
                break
            }
        }

        private func localName(_ qualified: String) -> String {
            if let colon = qualified.firstIndex(of: ":") {
                return String(qualified[qualified.index(after: colon)...])
            }
            return qualified
        }
    }

    private final class LanguageDelegate: NSObject, XMLParserDelegate {
        var language: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard localName(elementName) == "tt" else { return }
            language = attributeDict["xml:lang"] ?? attributeDict["lang"]
            parser.abortParsing()
        }

        private func localName(_ qualified: String) -> String {
            if let colon = qualified.firstIndex(of: ":") {
                return String(qualified[qualified.index(after: colon)...])
            }
            return qualified
        }
    }
}
