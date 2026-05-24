import Foundation

nonisolated enum MediaCacheNamespace: String, Sendable {
    case artwork
    case lyrics
    case translation
}

nonisolated struct MediaCacheKey: Hashable, Sendable {
    let namespace: MediaCacheNamespace
    let rawValue: String
}

nonisolated enum MediaCachePayload: Equatable, Sendable {
    case text(String)
    case data(Data)
    case unavailable
}

protocol MediaCache: Sendable {
    func value(for key: MediaCacheKey) async -> MediaCachePayload?
    func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async
    func removeAll() async
}

actor EphemeralMediaCache: MediaCache {
    private var storage: [MediaCacheKey: MediaCachePayload] = [:]

    func value(for key: MediaCacheKey) async -> MediaCachePayload? {
        storage[key]
    }

    func store(_ payload: MediaCachePayload, for key: MediaCacheKey) async {
        storage[key] = payload
    }

    func removeAll() async {
        storage.removeAll(keepingCapacity: false)
    }
}
