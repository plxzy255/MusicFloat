import Foundation
import OSLog

enum AppTelemetry {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cv.MusicFloat"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "Performance")

    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
    static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
    static let windowing = Logger(subsystem: subsystem, category: "Windowing")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let performance = Logger(subsystem: subsystem, category: "Performance")

    static var isVerbosePlaybackTelemetryEnabled: Bool {
        CommandLine.arguments.contains("--debug-playback-telemetry")
    }

    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: signpostID)
        defer {
            signposter.endInterval(name, state)
        }
        return try work()
    }

    static func measure<T>(_ name: StaticString, _ work: () async throws -> T) async rethrows -> T {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: signpostID)
        defer {
            signposter.endInterval(name, state)
        }
        return try await work()
    }
}
