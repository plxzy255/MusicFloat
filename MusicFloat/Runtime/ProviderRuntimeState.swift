import Foundation

nonisolated enum ProviderRuntimeState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable
    case failed(String)

    var displayName: String {
        switch self {
        case .idle:
            "Idle"
        case .loading:
            "Loading"
        case .ready:
            "Ready"
        case .unavailable:
            "Unavailable"
        case .failed:
            "Error"
        }
    }
}
