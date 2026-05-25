import Foundation
import OSLog
#if ENABLE_APPLE_TRANSLATION
import NaturalLanguage
@preconcurrency @unsafe import Translation

extension TranslationSession.Request: @unchecked @retroactive Sendable {}
#endif

struct TranslatedLyricLine: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let sourceLineID: LyricLine.ID
    let text: String
}

struct LyricTranslation: Codable, Equatable, Sendable {
    let targetLanguageIdentifier: String
    let sourceLanguageIdentifier: String?
    let lines: [TranslatedLyricLine]

    func text(for line: LyricLine) -> String? {
        lines.first { $0.sourceLineID == line.id }?.text
    }
}

enum TranslationRuntimeState: Equatable, Sendable {
    case idle
    case checkingAvailability
    case needsDownload(source: String, target: String)
    case translating
    case ready
    case sourceEqualsTarget
    case unsupported(source: String, target: String)
    case unavailable(reason: String)
    case failed(String)

    var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .checkingAvailability:
            "Checking availability"
        case .needsDownload:
            "Download needed"
        case .translating:
            "Translating"
        case .ready:
            "Ready"
        case .sourceEqualsTarget:
            "Source matches target"
        case .unsupported:
            "Unsupported"
        case .unavailable:
            "Unavailable"
        case .failed:
            "Error"
        }
    }

    var detailText: String {
        switch self {
        case .idle, .checkingAvailability, .translating, .ready, .sourceEqualsTarget:
            displayName
        case .needsDownload(let source, let target):
            "Download needed for \(Self.localizedName(for: source)) to \(Self.localizedName(for: target))"
        case .unsupported(let source, let target):
            "Unsupported: \(Self.localizedName(for: source)) to \(Self.localizedName(for: target))"
        case .unavailable(let reason), .failed(let reason):
            reason
        }
    }

    var downloadLanguages: (source: String, target: String)? {
        if case .needsDownload(let source, let target) = self {
            return (source, target)
        }
        return nil
    }

    private static func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

enum TranslationProviderResult: Equatable, Sendable {
    case available(LyricTranslation)
    case status(TranslationRuntimeState)
}

enum AppleTranslationAvailability: Equatable, Sendable {
    case installed
    case supported
    case unsupported
}

struct TranslationRequestPayload: Equatable, Sendable {
    let lineID: LyricLine.ID
    let text: String
}

struct TranslationResponsePayload: Equatable, Sendable {
    let lineID: LyricLine.ID
    let sourceLanguageIdentifier: String?
    let targetLanguageIdentifier: String
    let text: String
}

fileprivate func normalizedTranslationComparableText(_ text: String) -> String {
    text
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .components(separatedBy: .whitespacesAndNewlines)
        .joined()
        .trimmingCharacters(in: .punctuationCharacters)
}

@MainActor
protocol TranslationProvider {
    var displayName: String { get }

    func translation(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult
}

@MainActor
struct MockTranslationProvider: TranslationProvider {
    let displayName = "Mock translation provider"

    func translation(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult {
        .available(Self.previewTranslation(targetLanguageIdentifier: targetLanguageIdentifier))
    }

    static func previewTranslation(targetLanguageIdentifier: String) -> LyricTranslation {
        LyricTranslation(
            targetLanguageIdentifier: targetLanguageIdentifier,
            sourceLanguageIdentifier: "en",
            lines: [
                TranslatedLyricLine(id: 0, sourceLineID: 0, text: "L'app s'eveille doucement dans la barre de menus"),
                TranslatedLyricLine(id: 1, sourceLineID: 1, text: "Une ligne flottante attend la chanson"),
                TranslatedLyricLine(id: 2, sourceLineID: 2, text: "La traduction suit, douce et native"),
                TranslatedLyricLine(id: 3, sourceLineID: 3, text: "Chaque futur lien reste derriere une passerelle")
            ]
        )
    }
}

@MainActor
final class AppleTranslationProvider: TranslationProvider {
    let displayName = "Apple on-device translation"

    struct Dependencies {
        var availability: @MainActor (Locale.Language, Locale.Language) async -> AppleTranslationAvailability
        var translate: @MainActor (Locale.Language, Locale.Language, [TranslationRequestPayload]) async throws -> [TranslationResponsePayload]
        var inferSourceLanguageIdentifier: @MainActor ([LyricLine]) -> String? = { lines in
            AppleTranslationProvider.inferSourceLanguageIdentifier(from: lines)
        }
        var supportedLanguages: @MainActor () async -> [Locale.Language] = { [] }

        static let live = Dependencies(
            availability: { source, target in
                await AppleTranslationProvider.liveAvailability(source: source, target: target)
            },
            translate: { source, target, requests in
                try await AppleTranslationProvider.liveTranslate(
                    source: source,
                    target: target,
                    requests: requests
                )
            },
            inferSourceLanguageIdentifier: { lines in
                AppleTranslationProvider.inferSourceLanguageIdentifier(from: lines)
            },
            supportedLanguages: {
                await AppleTranslationProvider.liveSupportedLanguages()
            }
        )
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    nonisolated private static func liveAvailability(
        source: Locale.Language,
        target: Locale.Language
    ) async -> AppleTranslationAvailability {
        #if ENABLE_APPLE_TRANSLATION
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        switch await availability.status(from: source, to: target) {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unsupported
        }
        #else
        _ = source
        _ = target
        return .unsupported
        #endif
    }

    nonisolated private static func liveSupportedLanguages() async -> [Locale.Language] {
        #if ENABLE_APPLE_TRANSLATION
        let availability = LanguageAvailability(preferredStrategy: .lowLatency)
        return await availability.supportedLanguages
        #else
        return []
        #endif
    }

    nonisolated private static func liveTranslate(
        source: Locale.Language,
        target: Locale.Language,
        requests: [TranslationRequestPayload]
    ) async throws -> [TranslationResponsePayload] {
        #if ENABLE_APPLE_TRANSLATION
        let session = TranslationSession(
            installedSource: source,
            target: target,
            preferredStrategy: .lowLatency
        )
        let batch = requests.map { request in
            TranslationSession.Request(
                sourceText: request.text,
                clientIdentifier: String(request.lineID)
            )
        }
        let responses = try await session.translations(from: batch)
        return responses.compactMap { response in
            guard let clientIdentifier = response.clientIdentifier,
                  let lineID = Int(clientIdentifier) else {
                return nil
            }
            return TranslationResponsePayload(
                lineID: lineID,
                sourceLanguageIdentifier: response.sourceLanguage.minimalIdentifier,
                targetLanguageIdentifier: response.targetLanguage.minimalIdentifier,
                text: response.targetText
            )
        }
        #else
        _ = source
        _ = target
        _ = requests
        return []
        #endif
    }

    func translation(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult {
        await AppTelemetry.measure("AppleTranslationProvider.translation") {
            await translationImpl(for: document, targetLanguageIdentifier: targetLanguageIdentifier)
        }
    }

    private func translationImpl(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult {
        let requests = document.lines.compactMap { line -> TranslationRequestPayload? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranslationRequestPayload(lineID: line.id, text: text)
        }
        guard !requests.isEmpty else {
            return .status(.unavailable(reason: "No lyric lines to translate"))
        }

        #if ENABLE_APPLE_TRANSLATION
        guard let normalizedTarget = LyricsDocument.normalizedLanguageIdentifier(targetLanguageIdentifier) else {
            return .status(.unavailable(reason: "Language unavailable"))
        }

        let targetLanguage = Locale.Language(identifier: normalizedTarget)
        guard let normalizedSource = resolvedSourceLanguageIdentifier(
            for: document,
            targetLanguage: targetLanguage
        ) else {
            return .status(.unavailable(reason: "Source language unavailable"))
        }

        let sourceLanguage = Locale.Language(identifier: normalizedSource)
        if Self.sameLanguageFamily(sourceLanguage, targetLanguage) {
            return .status(.sourceEqualsTarget)
        }

        let supportedLanguages = await dependencies.supportedLanguages()
        guard supportedLanguages.isEmpty
                || (Self.isLanguageSupportedByTranslation(sourceLanguage, supportedLanguages: supportedLanguages)
                    && Self.isLanguageSupportedByTranslation(targetLanguage, supportedLanguages: supportedLanguages)) else {
            AppTelemetry.performance.notice(
                "Apple translation unsupported language source=\(normalizedSource, privacy: .public) target=\(normalizedTarget, privacy: .public)"
            )
            return .status(.unsupported(source: normalizedSource, target: normalizedTarget))
        }

        let availability = await dependencies.availability(sourceLanguage, targetLanguage)
        guard !Task.isCancelled else {
            return .status(.unavailable(reason: "Translation cancelled"))
        }

        switch availability {
        case .installed:
            break
        case .supported:
            return .status(.needsDownload(source: normalizedSource, target: normalizedTarget))
        case .unsupported:
            return .status(.unsupported(source: normalizedSource, target: normalizedTarget))
        }

        do {
            let responses = try await dependencies.translate(sourceLanguage, targetLanguage, requests)
            guard !Task.isCancelled else {
                return .status(.unavailable(reason: "Translation cancelled"))
            }

            let sourceByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.lineID, $0.text) })
            let lines = responses
                .filter { response in
                    let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return false }
                    guard let source = sourceByID[response.lineID] else { return false }
                    return !normalizedTranslationComparableText(text)
                        .elementsEqual(normalizedTranslationComparableText(source))
                }
                .sorted { $0.lineID < $1.lineID }
                .enumerated()
                .map { offset, response in
                    TranslatedLyricLine(
                        id: offset,
                        sourceLineID: response.lineID,
                        text: response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }

            guard !lines.isEmpty else {
                return .status(.unavailable(reason: "No distinct translated lines"))
            }

            return .available(LyricTranslation(
                targetLanguageIdentifier: normalizedTarget,
                sourceLanguageIdentifier: normalizedSource,
                lines: lines
            ))
        } catch is CancellationError {
            return .status(.unavailable(reason: "Translation cancelled"))
        } catch {
            let reason = Self.failureMessage(for: error)
            AppTelemetry.performance.error("Apple translation failed: \(error.localizedDescription, privacy: .public)")
            return .status(.failed(reason))
        }
        #else
        return .status(.unavailable(reason: "Apple Translation is not enabled in this build"))
        #endif
    }

    private func resolvedSourceLanguageIdentifier(
        for document: LyricsDocument,
        targetLanguage: Locale.Language
    ) -> String? {
        let explicitSource = LyricsDocument.normalizedLanguageIdentifier(document.sourceLanguageIdentifier)
        guard let explicitSource else {
            return LyricsDocument.normalizedLanguageIdentifier(
                dependencies.inferSourceLanguageIdentifier(document.lines)
            )
        }

        let explicitLanguage = Locale.Language(identifier: explicitSource)
        guard Self.sameLanguageFamily(explicitLanguage, targetLanguage) else {
            return explicitSource
        }

        guard let inferredSource = LyricsDocument.normalizedLanguageIdentifier(
            dependencies.inferSourceLanguageIdentifier(document.lines)
        ) else {
            return explicitSource
        }

        let inferredLanguage = Locale.Language(identifier: inferredSource)
        guard !Self.sameLanguageFamily(inferredLanguage, targetLanguage) else {
            return explicitSource
        }

        AppTelemetry.performance.notice(
            "Translation source language corrected explicit=\(explicitSource, privacy: .public) inferred=\(inferredSource, privacy: .public) target=\(targetLanguage.minimalIdentifier, privacy: .public)"
        )
        return inferredSource
    }

    private static func failureMessage(for error: any Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "Translation failed"
        }
        return "Translation failed: \(detail)"
    }

    private static func isLanguageSupportedByTranslation(
        _ language: Locale.Language,
        supportedLanguages: [Locale.Language]
    ) -> Bool {
        supportedLanguages.contains { supportedLanguage in
            supportedLanguage.minimalIdentifier == language.minimalIdentifier
                || sameLanguageFamily(supportedLanguage, language)
        }
    }

    private static func sameLanguageFamily(_ source: Locale.Language, _ target: Locale.Language) -> Bool {
        if source.minimalIdentifier == target.minimalIdentifier {
            return true
        }
        guard let sourceCode = source.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier else {
            return false
        }
        return sourceCode == targetCode
    }

    static func inferSourceLanguageIdentifier(from lines: [LyricLine]) -> String? {
        #if ENABLE_APPLE_TRANSLATION
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

        return LyricsDocument.normalizedLanguageIdentifier(language.rawValue)
        #else
        _ = lines
        return nil
        #endif
    }

}

#if ENABLE_APPLE_TRANSLATION
@MainActor
enum PreparedTranslationSessionTranslator {
    static func translation(
        using session: TranslationSession,
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async throws -> LyricTranslation? {
        let requests = document.lines.compactMap { line -> (lineID: LyricLine.ID, text: String)? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return (line.id, text)
        }
        guard !requests.isEmpty else { return nil }

        let batch = requests.map { request in
            TranslationSession.Request(
                sourceText: request.text,
                clientIdentifier: String(request.lineID)
            )
        }
        let responses = try await session.translations(from: batch)
        let sourceByID = Dictionary(uniqueKeysWithValues: requests)
        let translatedLines = responses
            .compactMap { response -> (lineID: LyricLine.ID, sourceLanguageIdentifier: String, text: String)? in
                guard let clientIdentifier = response.clientIdentifier,
                      let lineID = Int(clientIdentifier),
                      let source = sourceByID[lineID] else {
                    return nil
                }
                let text = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty,
                      !normalizedTranslationComparableText(text)
                        .elementsEqual(normalizedTranslationComparableText(source)) else {
                    return nil
                }
                return (lineID, response.sourceLanguage.minimalIdentifier, text)
            }
            .sorted { $0.lineID < $1.lineID }
        guard !translatedLines.isEmpty else { return nil }

        return LyricTranslation(
            targetLanguageIdentifier: LyricsDocument.normalizedLanguageIdentifier(targetLanguageIdentifier)
                ?? targetLanguageIdentifier,
            sourceLanguageIdentifier: translatedLines.first?.sourceLanguageIdentifier
                ?? document.sourceLanguageIdentifier,
            lines: translatedLines.enumerated().map { offset, line in
                TranslatedLyricLine(id: offset, sourceLineID: line.lineID, text: line.text)
            }
        )
    }

}
#endif

@MainActor
struct ExperimentalTranslationProviderPlaceholder: TranslationProvider {
    let displayName = "Experimental translation provider placeholder"

    func translation(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult {
        .status(.unavailable(reason: "Experimental translation disabled"))
    }
}

@MainActor
struct DisabledTranslationProvider: TranslationProvider {
    let displayName = "Disabled translation provider"

    func translation(
        for document: LyricsDocument,
        targetLanguageIdentifier: String
    ) async -> TranslationProviderResult {
        .status(.idle)
    }
}
