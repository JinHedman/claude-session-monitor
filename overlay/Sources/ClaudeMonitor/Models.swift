import Foundation

// MARK: - Session Status

enum SessionStatus: String, Codable {
    case active
    case waiting_input
    case needs_permission
    case idle        // Claude finished its turn, waiting for your next prompt
    case completed   // Explicitly cleared — removed by cleanup task

    // Handles unknown values gracefully without crashing.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .completed
    }
}

// MARK: - Agent

struct Agent: Codable, Identifiable {
    let id: String
    let session_id: String
    let agent_name: String
    let parent_session_id: String?
    let status: SessionStatus
    let created_at: String
    let updated_at: String

    // Backend sends UUIDs; decode as String regardless of UUID representation.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id may arrive as a UUID object or a UUID-formatted string
        if let uuid = try? c.decode(UUID.self, forKey: .id) {
            id = uuid.uuidString.lowercased()
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        session_id = try c.decode(String.self, forKey: .session_id)
        agent_name = try c.decode(String.self, forKey: .agent_name)
        parent_session_id = try c.decodeIfPresent(String.self, forKey: .parent_session_id)
        status = try c.decode(SessionStatus.self, forKey: .status)
        created_at = (try? c.decode(String.self, forKey: .created_at)) ?? ""
        updated_at = (try? c.decode(String.self, forKey: .updated_at)) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case id, session_id, agent_name, parent_session_id, status, created_at, updated_at
    }
}

// MARK: - Session

struct Session: Codable, Identifiable {
    let id: String
    let session_id: String
    let project_name: String
    let project_path: String
    let status: SessionStatus
    let created_at: String
    let updated_at: String
    let agents: [Agent]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? c.decode(UUID.self, forKey: .id) {
            id = uuid.uuidString.lowercased()
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        session_id = try c.decode(String.self, forKey: .session_id)
        project_name = try c.decode(String.self, forKey: .project_name)
        project_path = try c.decode(String.self, forKey: .project_path)
        status = try c.decode(SessionStatus.self, forKey: .status)
        created_at = (try? c.decode(String.self, forKey: .created_at)) ?? ""
        updated_at = (try? c.decode(String.self, forKey: .updated_at)) ?? ""
        agents = (try? c.decode([Agent].self, forKey: .agents)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, session_id, project_name, project_path, status, created_at, updated_at, agents
    }
}
