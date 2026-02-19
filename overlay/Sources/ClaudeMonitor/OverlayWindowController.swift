import AppKit
import SwiftUI

final class OverlayWindowController: NSWindowController {

    /// Shared reference used by FloatingHeaderBar's SwiftUI DragGesture to move the window.
    static weak var overlayWindow: NSWindow?

    private var hostingView: NSHostingView<OverlayView>?

    // MARK: - Init

    convenience init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.init(window: panel)

        configurePanel(panel)
        buildContent(in: panel)
        positionWindow()
    }

    // MARK: - Panel Configuration

    private func configurePanel(_ panel: NSPanel) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false           // Cards carry their own shadows
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false // Header uses SwiftUI DragGesture via overlayWindow
        panel.acceptsMouseMovedEvents = true
    }

    // MARK: - Content

    private func buildContent(in panel: NSPanel) {
        let overlayView = OverlayView(store: SessionStore.shared)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // Transparent so individual cards show through
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        panel.contentView = hosting
        self.hostingView = hosting
        OverlayWindowController.overlayWindow = panel
    }

    // MARK: - Positioning

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let maxHeight = frame.height * 0.80
        let width: CGFloat = 340
        let margin: CGFloat = 20

        let x = frame.maxX - width - margin
        let y = frame.maxY - maxHeight - margin

        window?.setFrame(NSRect(x: x, y: y, width: width, height: maxHeight), display: false)
    }

    // MARK: - Show / Hide

    func showOverlay() {
        positionWindow()
        window?.orderFront(nil)
    }

    func hideOverlay() {
        window?.orderOut(nil)
    }
}
