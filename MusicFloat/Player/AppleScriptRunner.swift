import Foundation
import OSAKit
import OSLog

/// Minimal AppleScript wrapper for the small queries we issue against Music.app.
///
/// Kept intentionally tiny: a single string-result entry point and a single
/// descriptor entry point for future use. AppleScript is not Sendable, so we
/// confine compilation+execution to the main actor; the queries are sub-millisecond.
@MainActor
enum AppleScriptRunner {
    /// Runs `source` and returns the string description of its result.
    /// Returns `nil` on compile or execution error.
    static func runString(_ source: String) -> String? {
        let script = OSAScript(source: source, language: OSALanguage(forName: "AppleScript"))
        var errorInfo: NSDictionary?
        guard let descriptor = script.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                AppTelemetry.performance.error(
                    "AppleScript error: \(String(describing: errorInfo[OSAScriptErrorMessageKey]), privacy: .public)"
                )
            }
            return nil
        }
        return descriptor.stringValue
    }
}
