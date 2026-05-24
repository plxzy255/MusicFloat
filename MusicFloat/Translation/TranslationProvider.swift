import Foundation

struct TranslatedLyricLine: Equatable, Identifiable, Sendable {
    let id: Int
    let sourceLineID: LyricLine.ID
    let text: String
}

struct LyricTranslation: Equatable, Sendable {
    let targetLanguage: String
    let lines: [TranslatedLyricLine]

    func text(for line: LyricLine) -> String? {
        lines.first { $0.sourceLineID == line.id }?.text
    }
}

enum TranslationProviderResult: Equatable, Sendable {
    case available(LyricTranslation)
    case unavailable
    case failed(String)
}

@MainActor
protocol TranslationProvider {
    var displayName: String { get }

    func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult
}

struct MockTranslationProvider: TranslationProvider {
    let displayName = "Mock translation provider"

    func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult {
        .available(Self.previewTranslation(targetLanguage: targetLanguage))
    }

    static func previewTranslation(targetLanguage: String) -> LyricTranslation {
        LyricTranslation(
            targetLanguage: targetLanguage,
            lines: [
                TranslatedLyricLine(id: 0, sourceLineID: 0, text: "L'app s'eveille doucement dans la barre de menus"),
                TranslatedLyricLine(id: 1, sourceLineID: 1, text: "Une ligne flottante attend la chanson"),
                TranslatedLyricLine(id: 2, sourceLineID: 2, text: "La traduction suit, douce et native"),
                TranslatedLyricLine(id: 3, sourceLineID: 3, text: "Chaque futur lien reste derriere une passerelle")
            ]
        )
    }
}

struct PublicTranslationProviderPlaceholder: TranslationProvider {
    let displayName = "Public translation provider placeholder"

    func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult {
        .unavailable
    }
}

struct ExperimentalTranslationProviderPlaceholder: TranslationProvider {
    let displayName = "Experimental translation provider placeholder"

    func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult {
        .unavailable
    }
}

struct DisabledTranslationProvider: TranslationProvider {
    let displayName = "Disabled translation provider"

    func translation(for document: LyricsDocument, targetLanguage: String) async -> TranslationProviderResult {
        .unavailable
    }
}
