import AppKit
import OSLog
import SwiftUI

@MainActor
final class FloatingPanelController {
    private var panel: NSPanel?

    func show(appState: AppState) {
        AppTelemetry.measure("FloatingPanelShow") {
            let didCreatePanel = panel == nil
            let panel = panel ?? makePanel(appState: appState)
            self.panel = panel
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
        let panelSize = NSSize(width: appState.overlayWidthPreset.width, height: 172)
        panel.setContentSize(panelSize)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)
    }

    private func makePanel(appState: AppState) -> NSPanel {
        AppTelemetry.measure("FloatingPanelCreate") {
            AppTelemetry.windowing.info("Create floating panel")
            let panelWidth = CGFloat(appState.overlayWidthPreset.width)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 172),
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

            let hostingView = NSHostingView(rootView: LyricsOverlayView(appState: appState))
            hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 172)
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
