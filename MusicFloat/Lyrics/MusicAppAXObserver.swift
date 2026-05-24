import Foundation
import AppKit
import ApplicationServices
import OSLog

/// Watches Music.app's accessibility tree and fires `onChange` whenever the
/// lyrics panel's selection or value mutates.
///
/// Replaces the 0.75 s polling loop with push notifications: the AX observer
/// callback runs on the main run loop within a few ms of Music.app updating
/// the highlighted lyric line. A periodic fallback in
/// `ProviderPipelineController` still runs at a lower cadence so we recover
/// even if the observer fails to attach (Music not running, panel closed,
/// Accessibility permission revoked mid-session).
@MainActor
final class MusicAppAXObserver {
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var onChange: (() -> Void)?
    private var launchToken: (any NSObjectProtocol)?
    private var terminateToken: (any NSObjectProtocol)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        attachIfPossible()

        let center = NSWorkspace.shared.notificationCenter
        launchToken = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }
            Task { @MainActor in self?.attachIfPossible() }
        }
        terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }
            Task { @MainActor in self?.detach() }
        }
    }

    func stop() {
        detach()
        onChange = nil
        let center = NSWorkspace.shared.notificationCenter
        if let launchToken { center.removeObserver(launchToken) }
        if let terminateToken { center.removeObserver(terminateToken) }
        launchToken = nil
        terminateToken = nil
    }

    private func attachIfPossible() {
        guard observer == nil else { return }
        guard AXIsProcessTrusted() else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Music")
            .first(where: { !$0.isTerminated }) else {
            return
        }

        var newObserver: AXObserver?
        let result = unsafe AXObserverCreate(
            app.processIdentifier,
            { _, _, _, refcon in
                guard let refcon else { return }
                let observer = unsafe Unmanaged<MusicAppAXObserver>.fromOpaque(refcon).takeUnretainedValue()
                Task { @MainActor in observer.onChange?() }
            },
            &newObserver
        )
        guard result == .success, let createdObserver = newObserver else {
            AppTelemetry.performance.error("AXObserverCreate failed for Music.app rc=\(result.rawValue)")
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // kAXSelectedChildrenChangedNotification fires when the active button
        // selection moves; kAXValueChangedNotification picks up label updates
        // for cases where Music swaps the button text in place rather than
        // moving selection.
        for notification in [
            kAXSelectedChildrenChangedNotification,
            kAXValueChangedNotification,
            kAXFocusedUIElementChangedNotification
        ] {
            let addResult = unsafe AXObserverAddNotification(
                createdObserver,
                appElement,
                notification as CFString,
                refcon
            )
            if addResult != .success && addResult != .notificationAlreadyRegistered {
                AppTelemetry.performance.info("AXObserver subscribe \(notification, privacy: .public) rc=\(addResult.rawValue)")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .defaultMode
        )
        observer = createdObserver
        observedPID = app.processIdentifier
        AppTelemetry.performance.info("AXObserver attached to Music.app pid=\(app.processIdentifier)")
    }

    private func detach() {
        guard let observer else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
        self.observer = nil
        observedPID = 0
        AppTelemetry.performance.info("AXObserver detached from Music.app")
    }
}
