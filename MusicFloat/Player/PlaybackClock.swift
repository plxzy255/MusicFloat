import Foundation

struct PlaybackClock: Sendable {
    private let initialState: PlayerState
    private var elapsedTime: TimeInterval

    init(initialState: PlayerState) {
        self.initialState = initialState
        elapsedTime = initialState.elapsedTime
    }

    mutating func tick(by interval: TimeInterval = 1) -> PlayerState {
        elapsedTime += interval

        return PlayerState(
            playbackStatus: initialState.playbackStatus,
            track: initialState.track,
            elapsedTime: elapsedTime,
            updatedAt: Date()
        )
    }
}
