import SwiftUI

// MARK: - SessionCardView

struct SessionCardView: View {
    let session: Session
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var isHovered = false

    private var hasSubagents: Bool { session.agents.count > 0 }

    /// Display name: project folder basename, fall back to session id.
    private var displayName: String {
        let path = session.project_path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let last = (path as NSString).lastPathComponent
        if !last.isEmpty { return last }
        let name = session.project_name
        return (!name.isEmpty && name != "unknown") ? name : session.session_id
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded && hasSubagents {
                agentList
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.17))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        // Subtle colored top accent for active/waiting sessions
        .overlay(alignment: .top) {
            if session.status != .completed {
                Rectangle()
                    .fill(accentGradient)
                    .frame(height: 1)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .inset(by: 0)
                    )
                    .mask(alignment: .top) {
                        Rectangle().frame(height: 1)
                    }
            }
        }
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
        .shadow(
            color: statusGlowColor.opacity(session.status == .completed ? 0 : 0.12),
            radius: 8, x: 0, y: 0
        )
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            StatusDotView(status: session.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(statusLabel(session.status))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 6) {
                // Focus button — click to switch to terminal tab
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 0.65 : 0.22))
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture {
                        TerminalFocus.focus(
                            projectPath: session.project_path,
                            sessionId: session.session_id,
                            transcriptPath: session.transcript_path,
                            tty: session.tty
                        )
                    }

                if hasSubagents {
                    Text("\(session.agents.count) \(session.agents.count == 1 ? "agent" : "agents")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.10))
                        .foregroundColor(.white.opacity(0.65))
                        .clipShape(Capsule())

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color.white.opacity(isHovered ? 0.07 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onTapGesture {
            // Tap on card body = expand/collapse (no terminal focus)
            if hasSubagents {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    onToggleExpand()
                }
            } else {
                // No agents to expand — focus terminal instead
                TerminalFocus.focus(
                    projectPath: session.project_path,
                    sessionId: session.session_id,
                    transcriptPath: session.transcript_path,
                    tty: session.tty
                )
            }
        }
    }

    // MARK: Agent List

    private var agentList: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.horizontal, 14)

            VStack(spacing: 5) {
                ForEach(session.agents) { agent in
                    AgentRowView(agent: agent, projectPath: session.project_path, sessionId: session.session_id, tty: session.tty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Helpers

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status {
        case .active:            return "Working..."
        case .waiting_input:     return "Waiting for input"
        case .needs_permission:  return "Permission needed"
        case .idle:              return "Waiting for prompt"
        case .completed:         return "Completed"
        }
    }

    private var statusGlowColor: Color {
        switch session.status {
        case .active:            return Color(hex: "F97316")
        case .waiting_input:     return Color(hex: "10B981")
        case .needs_permission:  return Color(hex: "EF4444")
        case .idle:              return Color(hex: "10B981")
        case .completed:         return Color(hex: "6B7280")
        }
    }

    private var accentGradient: LinearGradient {
        let color = statusGlowColor
        return LinearGradient(
            colors: [color.opacity(0), color.opacity(0.8), color.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - StatusDotView

struct StatusDotView: View {
    let status: SessionStatus
    @State private var isPulsing = false

    var dotColor: Color {
        switch status {
        case .active:            return Color(hex: "F97316")
        case .waiting_input:     return Color(hex: "10B981")
        case .needs_permission:  return Color(hex: "EF4444")
        case .idle:              return Color(hex: "10B981")
        case .completed:         return Color(hex: "6B7280")
        }
    }

    var body: some View {
        ZStack {
            if status == .active || status == .waiting_input {
                // Outer pulse ring
                Circle()
                    .fill(dotColor.opacity(isPulsing ? 0 : 0.25))
                    .frame(
                        width: isPulsing ? 20 : 10,
                        height: isPulsing ? 20 : 10
                    )
                    .animation(
                        .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                        value: isPulsing
                    )

                // Middle ring
                Circle()
                    .fill(dotColor.opacity(isPulsing ? 0 : 0.15))
                    .frame(
                        width: isPulsing ? 14 : 10,
                        height: isPulsing ? 14 : 10
                    )
                    .animation(
                        .easeOut(duration: 1.4).delay(0.1).repeatForever(autoreverses: false),
                        value: isPulsing
                    )
            }

            // Solid center dot
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .shadow(color: dotColor.opacity(0.7), radius: 5)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isPulsing = true
            }
        }
    }
}

// MARK: - AgentRowView

struct AgentRowView: View {
    let agent: Agent
    let projectPath: String
    let sessionId: String
    let tty: String

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(agentColor)
                .frame(width: 6, height: 6)
                .shadow(color: agentColor.opacity(0.5), radius: 3)

            Text(agent.agent_name)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)

            Spacer()

            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white.opacity(isHovered ? 0.55 : 0.15))

            Text(agent.status.rawValue.replacingOccurrences(of: "_", with: " "))
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.38))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.10 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(isHovered ? 0.13 : 0.07), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onTapGesture {
            TerminalFocus.focus(projectPath: projectPath, sessionId: sessionId, tty: tty)
        }

    }

    private var agentColor: Color {
        switch agent.status {
        case .active:            return Color(hex: "F97316")
        case .waiting_input:     return Color(hex: "10B981")
        case .needs_permission:  return Color(hex: "EF4444")
        case .idle:              return Color(hex: "10B981")
        case .completed:         return Color(hex: "6B7280")
        }
    }
}
