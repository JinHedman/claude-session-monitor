import SwiftUI

struct OverlayView: View {
    @ObservedObject var store: SessionStore

    @State private var expandedIds: Set<String> = []
    @State private var isCollapsed = false
    @State private var showClearConfirm = false

    private var activeSessions: [Session] {
        store.sessions.filter { $0.status != .completed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FloatingHeaderBar(
                isCollapsed: isCollapsed,
                onToggleCollapse: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        isCollapsed.toggle()
                    }
                },
                onClearTapped: { showClearConfirm = true }
            )
            .alert("Clear all sessions?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) {
                    Task { await store.clearAllSessions() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes all session history from the database. The tables are preserved.")
            }

            if !isCollapsed {
                if activeSessions.isEmpty {
                    FloatingEmptyCard()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    ForEach(activeSessions) { session in
                        SessionCardView(
                            session: session,
                            isExpanded: expandedIds.contains(session.id),
                            onToggleExpand: { toggleExpand(session.id) }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: 340, maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: activeSessions.map { $0.id })
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCollapsed)
    }

    private func toggleExpand(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }
}

// MARK: - Header Bar

struct FloatingHeaderBar: View {
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    let onClearTapped: () -> Void

    @State private var dragStartOrigin: NSPoint? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: "F97316"))
                .frame(width: 7, height: 7)
                .shadow(color: Color(hex: "F97316").opacity(0.7), radius: 4)

            Text("Claude Sessions")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.88))

            Spacer()

            // Collapse / expand all session cards
            Button(action: onToggleCollapse) {
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand sessions" : "Collapse sessions")

            // Clear database
            Button(action: onClearTapped) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Clear all sessions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "111111").opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 4)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    guard let window = OverlayWindowController.overlayWindow else { return }
                    if dragStartOrigin == nil {
                        dragStartOrigin = window.frame.origin
                    }
                    guard let start = dragStartOrigin else { return }
                    window.setFrameOrigin(NSPoint(
                        x: start.x + value.translation.width,
                        y: start.y - value.translation.height
                    ))
                }
                .onEnded { _ in dragStartOrigin = nil }
        )
    }
}

// MARK: - Empty State

struct FloatingEmptyCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 13, weight: .light))
                .foregroundColor(Color(hex: "F97316").opacity(0.45))
            Text("No active sessions")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "111111").opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 3)
    }
}
