import AppKit
import SwiftUI

/// Invisible drag handle placed only in the header bar.
/// Uses performDrag so ONLY the header moves the window —
/// session cards are fully clickable.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

final class DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        // Initiate window drag from this specific view only.
        window?.performDrag(with: event)
    }
}
