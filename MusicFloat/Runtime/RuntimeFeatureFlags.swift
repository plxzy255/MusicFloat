import Foundation

nonisolated enum RuntimeAdapterMode: String, CaseIterable, Identifiable, Sendable {
    case mock
    case publicApple
    case experimental
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mock:
            "Mock"
        case .publicApple:
            "Public Apple API"
        case .experimental:
            "Experimental"
        case .disabled:
            "Disabled"
        }
    }
}

nonisolated struct RuntimeFeatureFlags: Equatable, Sendable {
    var playerBridgeMode: RuntimeAdapterMode
    var lyricsProviderMode: RuntimeAdapterMode
    var translationProviderMode: RuntimeAdapterMode
    var allowsHiddenProviderRefresh: Bool

    static let architectureDefault = RuntimeFeatureFlags(
        playerBridgeMode: .mock,
        lyricsProviderMode: .mock,
        translationProviderMode: .mock,
        allowsHiddenProviderRefresh: false
    )
}
