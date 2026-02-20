import SwiftUI

// MARK: - SessionCardView

struct SessionCardView: View {
    let session: Session
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    @State private var claudeTitle: String? = nil
    @State private var isHovered = false

    private var hasSubagents: Bool { session.agents.count > 0 }

    /// Use Claude CLI session summary if available, otherwise path basename.
    /// Shows "~" for the home directory.
    private var displayName: String {
        if let title = claudeTitle, !title.isEmpty { return title }
        let path = session.project_path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let last = (path as NSString).lastPathComponent
        if !last.isEmpty { return last }
        // Ultimate fallback
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
        .onAppear { loadClaudeTitle() }
        .onChange(of: session.session_id) { _ in loadClaudeTitle() }
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
                // Focus indicator — always visible, brighter on hover
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 0.65 : 0.22))

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
            TerminalFocus.focus(projectPath: session.project_path, sessionId: session.session_id)
            if hasSubagents {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                    onToggleExpand()
                }
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
                    AgentRowView(agent: agent, projectPath: session.project_path, sessionId: session.session_id)
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

    private func loadClaudeTitle() {
        let projectPath = session.project_path
        let sessionId = session.session_id
        DispatchQueue.global(qos: .utility).async {
            let encodedPath = projectPath.replacingOccurrences(of: "/", with: "-")
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let projectDir = URL(fileURLWithPath: home)
                .appendingPathComponent(".claude/projects")
                .appendingPathComponent(encodedPath)

            // 1. Try sessions-index.json (populated after session ends)
            let indexURL = projectDir.appendingPathComponent("sessions-index.json")
            if let data = try? Data(contentsOf: indexURL) {
                struct IndexEntry: Decodable { let sessionId: String; let summary: String? }
                struct SessionsIndex: Decodable { let entries: [IndexEntry] }
                if let index = try? JSONDecoder().decode(SessionsIndex.self, from: data),
                   let summary = index.entries.first(where: { $0.sessionId == sessionId })?.summary,
                   !summary.isEmpty {
                    DispatchQueue.main.async { claudeTitle = summary }
                    return
                }
            }

            // 2. Fall back: read first user message from the JSONL transcript
            let jsonlURL = projectDir.appendingPathComponent("\(sessionId).jsonl")
            guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return }
            struct TranscriptLine: Decodable {
                let type: String?
                let message: MessageBody?
                struct MessageBody: Decodable {
                    let role: String?
                    let content: ContentValue?
                    enum ContentValue: Decodable {
                        case string(String)
                        case array([ContentBlock])
                        struct ContentBlock: Decodable {
                            let type: String?
                            let text: String?
                        }
                        init(from decoder: Decoder) throws {
                            let c = try decoder.singleValueContainer()
                            if let s = try? c.decode(String.self) { self = .string(s); return }
                            self = .array((try? c.decode([ContentBlock].self)) ?? [])
                        }
                        var text: String? {
                            switch self {
                            case .string(let s): return s
                            case .array(let blocks): return blocks.first(where: { $0.type == "text" })?.text
                            }
                        }
                    }
                }
            }
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(TranscriptLine.self, from: data),
                      entry.type == "user",
                      entry.message?.role == "user",
                      let text = entry.message?.content?.text,
                      !text.isEmpty else { continue }
                // Truncate to first 60 chars, strip newlines
                let clean = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
                let truncated = clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
                DispatchQueue.main.async { claudeTitle = truncated }
                return
            }
        }
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
            // Delay slightly so the window is visible before animating
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
            TerminalFocus.focus(projectPath: projectPath, sessionId: sessionId)
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
