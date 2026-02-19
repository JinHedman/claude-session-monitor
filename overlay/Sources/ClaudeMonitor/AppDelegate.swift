import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var overlayWindowController: OverlayWindowController?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            self.setupStatusItem()
            self.setupOverlayWindow()
            SessionStore.shared.startMonitoring()
            self.observeSessions()
        }
    }

    // MARK: - Status Bar

    @MainActor private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "circle.grid.2x2.fill",
                               accessibilityDescription: "Claude Monitor")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(handleStatusClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @MainActor @objc private func handleStatusClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusMenu()
        } else {
            guard let controller = overlayWindowController else { return }
            if controller.window?.isVisible == true {
                controller.hideOverlay()
            } else {
                controller.showOverlay()
            }
        }
    }

    @MainActor private func showStatusMenu() {
        let menu = NSMenu()
        let toggleTitle = overlayWindowController?.window?.isVisible == true
            ? "Hide Overlay" : "Show Overlay"
        menu.addItem(NSMenuItem(title: toggleTitle,
                                action: #selector(toggleOverlayFromMenu),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Monitor",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Clear so next left-click doesn't open menu
        DispatchQueue.main.async { self.statusItem.menu = nil }
    }

    @MainActor @objc private func toggleOverlayFromMenu() {
        guard let controller = overlayWindowController else { return }
        if controller.window?.isVisible == true {
            controller.hideOverlay()
        } else {
            controller.showOverlay()
        }
    }

    // MARK: - Overlay Window

    @MainActor private func setupOverlayWindow() {
        overlayWindowController = OverlayWindowController()
    }

    // MARK: - Session Observation

    @MainActor private func observeSessions() {
        SessionStore.shared.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                Task { @MainActor [weak self] in
                    self?.updateStatusItemAppearance(sessions: sessions)
                }
            }
            .store(in: &cancellables)
    }

    @MainActor private func updateStatusItemAppearance(sessions: [Session]) {
        guard let button = statusItem.button else { return }

        let activeSessions = sessions.filter { $0.status != .completed }
        let needsInput = sessions.contains { $0.status == .waiting_input }

        if activeSessions.isEmpty {
            // Idle: just show the icon
            button.image = NSImage(systemSymbolName: "circle.grid.2x2.fill",
                                   accessibilityDescription: "Claude Monitor")
            button.image?.isTemplate = true
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        } else if needsInput {
            // Waiting for input — amber dot
            button.image = nil
            let combined = makeStatusBarTitle(
                dotColor: NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1.0),
                count: activeSessions.count
            )
            button.attributedTitle = combined
        } else {
            // Active — purple dot
            button.image = nil
            let combined = makeStatusBarTitle(
                dotColor: NSColor(red: 0.545, green: 0.361, blue: 0.965, alpha: 1.0),
                count: activeSessions.count
            )
            button.attributedTitle = combined
        }
    }

    private func makeStatusBarTitle(dotColor: NSColor, count: Int) -> NSAttributedString {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let dot = NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dotColor,
            .font: monoFont
        ])
        let countStr = NSAttributedString(string: "\(count)", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: monoFont
        ])
        let combined = NSMutableAttributedString(attributedString: dot)
        combined.append(countStr)
        return combined
    }
}
