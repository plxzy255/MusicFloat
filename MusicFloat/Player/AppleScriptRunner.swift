import Foundation
import OSAKit
import OSLog

/// Minimal AppleScript wrapper for the small queries we issue against Music.app.
///
/// Kept intentionally tiny: string-result entry points only. AppleScript can
/// stall while Music.app is busy, so live-mode callers should use
/// `runStringOffMain(_:)` and then publish parsed state back on the main actor.
enum AppleScriptRunner {
    /// Runs `source` and returns the string description of its result.
    /// Returns `nil` on compile or execution error.
    nonisolated static func runString(_ source: String) -> String? {
        runStringImpl(source)
    }

    nonisolated static func runStringOffMain(_ source: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            runStringImpl(source)
        }.value
    }

    nonisolated private static func runStringImpl(_ source: String) -> String? {
        let script = OSAScript(source: source, language: OSALanguage(forName: "AppleScript"))
        var errorInfo: NSDictionary?
        guard let descriptor = script.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                let message = String(describing: errorInfo[OSAScriptErrorMessageKey])
                Task { @MainActor in
                    AppTelemetry.performance.error("AppleScript error: \(message, privacy: .public)")
                }
            }
            return nil
        }
        return descriptor.stringValue
    }
}
