import Foundation

// MARK: - Session Status

enum SessionStatus: String, Codable {
    case active
    case waiting_input
    case needs_permission
    case idle        // Claude finished its turn, waiting for your next prompt
    case completed   // Explicitly cleared — removed from overlay

    // Handles unknown values gracefully without crashing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .completed
    }
}

// MARK: - Hook Event (file JSON format)

struct HookEvent: Codable {
    let session_id: String
    let hook_event_name: String
    let timestamp: Double
    let cwd: String
    let notification_type: String
    let message: String
    let tool_name: String
    let tool_input: String
    let agent_name: String
    let agent_id: String
    let agent_type: String
    let transcript_path: String
    let user_prompt: String
    let reason: String
    let is_permission: Bool
    let is_interrupt: Bool
    let tty: String
    let ghostty_tty: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session_id = (try? c.decode(String.self, forKey: .session_id)) ?? ""
        hook_event_name = (try? c.decode(String.self, forKey: .hook_event_name)) ?? ""
        timestamp = (try? c.decode(Double.self, forKey: .timestamp)) ?? 0
        cwd = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        notification_type = (try? c.decode(String.self, forKey: .notification_type)) ?? ""
        message = (try? c.decode(String.self, forKey: .message)) ?? ""
        tool_name = (try? c.decode(String.self, forKey: .tool_name)) ?? ""
        // tool_input can be a string or a JSON object — coerce to string either way
        if let s = try? c.decode(String.self, forKey: .tool_input) {
            tool_input = s
        } else {
            tool_input = ""
        }
        agent_name = (try? c.decode(String.self, forKey: .agent_name)) ?? ""
        agent_id = (try? c.decode(String.self, forKey: .agent_id)) ?? ""
        agent_type = (try? c.decode(String.self, forKey: .agent_type)) ?? ""
        transcript_path = (try? c.decode(String.self, forKey: .transcript_path)) ?? ""
        user_prompt = (try? c.decode(String.self, forKey: .user_prompt)) ?? ""
        reason = (try? c.decode(String.self, forKey: .reason)) ?? ""
        is_permission = (try? c.decode(Bool.self, forKey: .is_permission)) ?? false
        is_interrupt = (try? c.decode(Bool.self, forKey: .is_interrupt)) ?? false
        tty = (try? c.decode(String.self, forKey: .tty)) ?? ""
        ghostty_tty = (try? c.decode(String.self, forKey: .ghostty_tty)) ?? ""
        agents = (try? c.decode([String: AgentEntry].self, forKey: .agents)) ?? [:]
    }

    let agents: [String: AgentEntry]

    enum CodingKeys: String, CodingKey {
        case session_id, hook_event_name, timestamp, cwd, notification_type,
             message, tool_name, tool_input, agent_name, agent_id, agent_type,
             transcript_path, user_prompt, reason, is_permission, is_interrupt, tty,
             ghostty_tty, agents
    }
}

// MARK: - Agent Entry (accumulated in session JSON by hook)

struct AgentEntry: Codable {
    let agent_id: String
    let agent_name: String
    let agent_type: String
    let status: String
    let started_at: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent_id = (try? c.decode(String.self, forKey: .agent_id)) ?? ""
        agent_name = (try? c.decode(String.self, forKey: .agent_name)) ?? ""
        agent_type = (try? c.decode(String.self, forKey: .agent_type)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "active"
        started_at = (try? c.decode(Double.self, forKey: .started_at)) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case agent_id, agent_name, agent_type, status, started_at
    }
}

// MARK: - Agent

struct Agent: Identifiable {
    let id: String
    let session_id: String
    let agent_name: String
    let agent_type: String
    let status: SessionStatus
    let created_at: Date
    let updated_at: Date
}

// MARK: - Session

struct Session: Identifiable {
    let id: String
    let session_id: String
    let project_name: String
    let project_path: String
    let status: SessionStatus
    let created_at: Date
    let updated_at: Date
    let agents: [Agent]
    let transcript_path: String
    let user_prompt: String
    let tty: String
    let ghostty_tty: String
}
