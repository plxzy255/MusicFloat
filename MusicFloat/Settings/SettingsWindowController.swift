import AppKit
import os
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(
        appState: AppState,
        onTranslationPreferencesChanged: @escaping () -> Void,
        onTranslationPreparationCompleted: @escaping () -> Void
    ) {
        let settingsView = SettingsView(
            appState: appState,
            onTranslationPreferencesChanged: onTranslationPreferencesChanged,
            onTranslationPreparationCompleted: onTranslationPreparationCompleted
        )

        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<SettingsView> {
                hostingController.rootView = settingsView
            } else {
                window.contentViewController = NSHostingController(rootView: settingsView)
            }
            show(window)
            return
        }

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MusicFloat Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 420, height: 520))
        window.center()
        self.window = window
        show(window)
    }

    private func show(_ window: NSWindow) {
        AppTelemetry.settings.info("Open settings window requested")
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
