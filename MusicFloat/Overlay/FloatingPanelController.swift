import AppKit
import OSLog
import SwiftUI

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?

    func show(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void = {},
        playbackCommands: LyricsOverlayPlaybackCommands = .disabled
    ) {
        AppTelemetry.measure("FloatingPanelShow") {
            let didCreatePanel = panel == nil
            let panel = panel ?? makePanel(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands
            )
            self.panel = panel
            updateContent(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands,
                in: panel
            )
            applySize(appState: appState, to: panel)

            AppTelemetry.windowing.info("Show floating panel created=\(didCreatePanel)")
            panel.orderFrontRegardless()
        }
    }

    func hide(releaseResources: Bool = false) {
        AppTelemetry.measure("FloatingPanelHide") {
            AppTelemetry.windowing.info(
                "Hide floating panel hasPanel=\(self.panel != nil) releaseResources=\(releaseResources)"
            )
            panel?.orderOut(nil)

            if releaseResources {
                panel?.contentView = nil
                panel = nil
            }
        }
    }

    private func applySize(appState: AppState, to panel: NSPanel) {
        let panelSize = NSSize(width: appState.overlayWidthPreset.width, height: LyricsOverlayLayout.panelHeight)
        panel.setContentSize(panelSize)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
    }

    private func updateContent(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void,
        playbackCommands: LyricsOverlayPlaybackCommands,
        in panel: NSPanel
    ) {
        guard let hostingView = panel.contentView as? NSHostingView<LyricsOverlayView> else { return }
        hostingView.rootView = LyricsOverlayView(
            appState: appState,
            onTranslationPreparationCompleted: onTranslationPreparationCompleted,
            playbackCommands: playbackCommands
        )
    }

    private func makePanel(
        appState: AppState,
        onTranslationPreparationCompleted: @escaping () -> Void,
        playbackCommands: LyricsOverlayPlaybackCommands
    ) -> NSPanel {
        AppTelemetry.measure("FloatingPanelCreate") {
            AppTelemetry.windowing.info("Create floating panel")
            let panelWidth = CGFloat(appState.overlayWidthPreset.width)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: LyricsOverlayLayout.panelHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true

            let hostingView = NSHostingView(rootView: LyricsOverlayView(
                appState: appState,
                onTranslationPreparationCompleted: onTranslationPreparationCompleted,
                playbackCommands: playbackCommands
            ))
            hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: LyricsOverlayLayout.panelHeight)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView

            if let screenFrame = NSScreen.main?.visibleFrame {
                let origin = NSPoint(
                    x: screenFrame.midX - panel.frame.width / 2,
                    y: screenFrame.maxY - panel.frame.height - 88
                )
                panel.setFrameOrigin(origin)
            }

            return panel
        }
    }
}
