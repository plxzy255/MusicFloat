import Foundation
@preconcurrency @unsafe import OSAKit
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
        runDescriptorImpl(source)?.stringValue
    }

    nonisolated static func runStringOffMain(_ source: String) async -> String? {
        await AppleScriptExecutor.shared.runString(source)
    }

    /// Runs `source` off the main actor and returns raw Apple event descriptor bytes.
    nonisolated static func runDataOffMain(_ source: String) async -> Data? {
        await AppleScriptExecutor.shared.runData(source)
    }

    nonisolated private static func runDescriptorImpl(_ source: String) -> NSAppleEventDescriptor? {
        let script = OSAScript(source: source, language: OSALanguage(forName: "AppleScript"))
        var errorInfo: NSDictionary?
        guard let descriptor = unsafe script.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                let message = appleScriptErrorMessage(errorInfo)
                Task { @MainActor in
                    AppTelemetry.performance.error("AppleScript error: \(message, privacy: .public)")
                }
            }
            return nil
        }
        return descriptor
    }
}

private actor AppleScriptExecutor {
    static let shared = AppleScriptExecutor()

    private let maxCachedScripts = 24
    private var scripts: [String: OSAScript] = [:]
    private var scriptAccessOrder: [String] = []
    private let language = OSALanguage(forName: "AppleScript")

    func runString(_ source: String) -> String? {
        runDescriptor(source)?.stringValue
    }

    func runData(_ source: String) -> Data? {
        runDescriptor(source)?.rawDescriptorData
    }

    private func runDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = compiledScript(for: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        guard let descriptor = unsafe script.executeAndReturnError(&errorInfo) else {
            if let errorInfo {
                logScriptError(errorInfo)
            }
            return nil
        }
        return descriptor
    }

    private func compiledScript(for source: String) -> OSAScript? {
        if let script = scripts[source] {
            recordScriptAccess(source)
            return script
        }

        let script = OSAScript(source: source, language: language)
        var errorInfo: NSDictionary?
        guard unsafe script.compileAndReturnError(&errorInfo) else {
            if let errorInfo {
                logScriptError(errorInfo)
            }
            return nil
        }

        scripts[source] = script
        scriptAccessOrder.append(source)
        evictOldScriptsIfNeeded()
        return script
    }

    private func recordScriptAccess(_ source: String) {
        scriptAccessOrder.removeAll { $0 == source }
        scriptAccessOrder.append(source)
    }

    private func evictOldScriptsIfNeeded() {
        while scripts.count > maxCachedScripts,
              let evictedSource = scriptAccessOrder.first {
            scriptAccessOrder.removeFirst()
            scripts.removeValue(forKey: evictedSource)
        }
    }

    private func logScriptError(_ errorInfo: NSDictionary) {
        let message = appleScriptErrorMessage(errorInfo)
        Task { @MainActor in
            AppTelemetry.performance.error("AppleScript error: \(message, privacy: .public)")
        }
    }
}

private nonisolated func appleScriptErrorMessage(_ errorInfo: NSDictionary) -> String {
    let message = (errorInfo[OSAScriptErrorMessageKey] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let number = errorInfo[OSAScriptErrorNumberKey].map { String(describing: $0) } ?? "unknown"
    if let message, !message.isEmpty {
        return "number=\(number) message=\(message)"
    }
    let keys = errorInfo.allKeys
        .map { String(describing: $0) }
        .sorted()
        .joined(separator: ",")
    return "number=\(number) message=unavailable keys=\(keys)"
}

private extension NSAppleEventDescriptor {
    nonisolated var rawDescriptorData: Data? {
        let payload = data
        if !payload.isEmpty { return payload }
        return coerce(toDescriptorType: typeData)?.data
    }
}
