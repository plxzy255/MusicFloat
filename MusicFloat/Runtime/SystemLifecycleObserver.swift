@preconcurrency @unsafe import AppKit
import Foundation

@MainActor
final class SystemLifecycleObserver {
    enum Event: String, Equatable, Sendable {
        case willSleep
        case didWake
        case sessionDidResignActive
        case sessionDidBecomeActive

        var telemetryName: String {
            rawValue
        }
    }

    struct NotificationNames: Sendable {
        let willSleep: Notification.Name
        let didWake: Notification.Name
        let sessionDidResignActive: Notification.Name
        let sessionDidBecomeActive: Notification.Name

        static let workspace = NotificationNames(
            willSleep: NSWorkspace.willSleepNotification,
            didWake: NSWorkspace.didWakeNotification,
            sessionDidResignActive: NSWorkspace.sessionDidResignActiveNotification,
            sessionDidBecomeActive: NSWorkspace.sessionDidBecomeActiveNotification
        )
    }

    private let notificationCenter: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    private var isObserving = true

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        notificationNames: NotificationNames = .workspace,
        onSuspend: @escaping @MainActor (Event) -> Void,
        onResume: @escaping @MainActor (Event) -> Void
    ) {
        self.notificationCenter = notificationCenter
        observe(notificationNames.willSleep, event: .willSleep, handler: onSuspend)
        observe(notificationNames.sessionDidResignActive, event: .sessionDidResignActive, handler: onSuspend)
        observe(notificationNames.didWake, event: .didWake, handler: onResume)
        observe(notificationNames.sessionDidBecomeActive, event: .sessionDidBecomeActive, handler: onResume)
    }

    deinit {
        isObserving = false
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }

    func stop() {
        isObserving = false
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
    }

    private func observe(
        _ name: Notification.Name,
        event: Event,
        handler: @escaping @MainActor (Event) -> Void
    ) {
        let token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                handler(event)
            }
        }
        tokens.append(token)
    }
}
