import Foundation
import Combine

// MARK: - Managed Session (internal state machine)

private struct ManagedSession {
    let sessionId: String
    var status: SessionStatus
    var projectPath: String
    var projectName: String
    var transcriptPath: String
    var userPrompt: String      // first user prompt (used as display title)
    var tty: String
    var createdAt: Date
    var updatedAt: Date
    var agents: [String: ManagedAgent]  // keyed by agent_id (fallback agent_name)

    struct ManagedAgent {
        let agentId: String
        let agentName: String
        let agentType: String
        var status: SessionStatus
        let createdAt: Date
        var updatedAt: Date
    }
}

@MainActor
final class SessionStore: ObservableObject {

    static let shared = SessionStore()

    @Published var sessions: [Session] = []

    private var managedSessions: [String: ManagedSession] = [:]
    private var fileHashes: [String: Int] = [:]  // sessionId → last seen content hash
    private var directoryMonitor: DispatchSourceFileSystemObject?
    private var scanTimer: Timer?
    private var stalenessTimer: Timer?

    private let sessionsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/monitor/sessions")
    }()

    private init() {}

    // MARK: - Public API

    func startMonitoring() {
        // Ensure directory exists
        try? FileManager.default.createDirectory(at: sessionsDir,
                                                  withIntermediateDirectories: true)
        // Rebuild state from existing files (crash recovery)
        scanSessionFiles()

        // Watch for file changes
        startDirectoryWatch()

        // Fallback polling timer (catches edge cases where DispatchSource misses)
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanSessionFiles()
            }
        }

        // Staleness timer: transition active sessions to idle if no updates for 30s
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkStaleSessions()
            }
        }
    }

    func clearAllSessions() async {
        // Delete all files in directory
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: sessionsDir,
                                                    includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                try? fm.removeItem(at: file)
            }
        }
        // Clear in-memory state
        managedSessions.removeAll()
        fileHashes.removeAll()
        publishSessions()
    }

    // MARK: - Directory Watching

    private func startDirectoryWatch() {
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.scanSessionFiles()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directoryMonitor = source
    }

    // MARK: - Staleness Check

    private func checkStaleSessions() {
        let now = Date()
        let sessionStaleThreshold: TimeInterval = 30
        let agentStaleThreshold: TimeInterval = 120   // 2 min — agents that missed their Stop
        let agentRemoveThreshold: TimeInterval = 15    // remove completed agents after 15s
        var changed = false

        for (sessionId, var session) in managedSessions {
            if session.status == .active,
               now.timeIntervalSince(session.updatedAt) > sessionStaleThreshold {
                session.status = .idle
                managedSessions[sessionId] = session
                changed = true
            }

            var agentsToRemove: [String] = []
            for (agentKey, agent) in session.agents {
                if agent.status == .active,
                   now.timeIntervalSince(agent.createdAt) > agentStaleThreshold {
                    // Auto-complete agents stuck in active state
                    session.agents[agentKey]?.status = .completed
                    session.agents[agentKey]?.updatedAt = now
                    managedSessions[sessionId] = session
                    changed = true
                } else if agent.status == .completed,
                          now.timeIntervalSince(agent.updatedAt) > agentRemoveThreshold {
                    // Remove completed agents after a short delay
                    agentsToRemove.append(agentKey)
                }
            }
            for key in agentsToRemove {
                session.agents.removeValue(forKey: key)
                managedSessions[sessionId] = session
                changed = true
            }
        }

        if changed {
            publishSessions()
        }
    }

    // MARK: - File Scanning & State Machine

    private func scanSessionFiles() {
        let fm = FileManager.default

        // Get current set of .json files
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let currentFileIds = Set(jsonFiles.map { $0.deletingPathExtension().lastPathComponent })

        // Remove sessions whose files have been deleted (SessionEnd)
        var changed = false
        for sessionId in managedSessions.keys where !currentFileIds.contains(sessionId) {
            managedSessions.removeValue(forKey: sessionId)
            fileHashes.removeValue(forKey: sessionId)
            changed = true
        }

        // Process each file
        for file in jsonFiles {
            let sessionId = file.deletingPathExtension().lastPathComponent

            guard let data = try? Data(contentsOf: file) else { continue }

            // Skip files whose content hasn't changed (byte-level hash)
            let hash = data.hashValue
            if fileHashes[sessionId] == hash { continue }
            fileHashes[sessionId] = hash

            guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
                continue
            }

            let now = Date(timeIntervalSince1970: event.timestamp)

            if var existing = managedSessions[sessionId] {
                let newStatus = resolveStatus(event: event, current: existing.status)

                // Keep the first CWD (from SessionStart), don't let later events overwrite
                if existing.projectPath.isEmpty && !event.cwd.isEmpty {
                    existing.projectPath = event.cwd
                    existing.projectName = (event.cwd as NSString).lastPathComponent
                }
                if !event.transcript_path.isEmpty {
                    existing.transcriptPath = event.transcript_path
                }
                // Capture first non-empty user_prompt as session title
                if existing.userPrompt.isEmpty && !event.user_prompt.isEmpty {
                    existing.userPrompt = event.user_prompt
                }
                // Update TTY (don't overwrite with empty)
                if !event.tty.isEmpty {
                    existing.tty = event.tty
                }
                existing.status = newStatus
                existing.updatedAt = now

                // Handle agents
                syncAgents(from: event, into: &existing)

                managedSessions[sessionId] = existing
                changed = true
            } else {
                // New session
                let projectName = event.cwd.isEmpty ? "unknown"
                    : (event.cwd as NSString).lastPathComponent
                var session = ManagedSession(
                    sessionId: sessionId,
                    status: resolveStatus(event: event, current: nil),
                    projectPath: event.cwd,
                    projectName: projectName,
                    transcriptPath: event.transcript_path,
                    userPrompt: event.user_prompt,
                    tty: event.tty,
                    createdAt: now,
                    updatedAt: now,
                    agents: [:]
                )
                syncAgents(from: event, into: &session)
                managedSessions[sessionId] = session
                changed = true
            }
        }

        if changed {
            publishSessions()
        }
    }

    /// State machine: determine new status from hook event
    private func resolveStatus(event: HookEvent, current: SessionStatus?) -> SessionStatus {
        switch event.hook_event_name {
        case "Stop":
            // Only transition to idle if currently active
            if current == .active { return .idle }
            return current ?? .idle

        case "Notification":
            if event.is_permission || event.notification_type == "permission_prompt" {
                return .needs_permission
            }
            return .waiting_input

        case "SubagentStart":
            return .active

        case "SubagentStop":
            // Session stays at whatever status it was (agent completed, not session)
            return current ?? .active

        case "UserPromptSubmit":
            // User submitted input → session is active again
            return .active

        case "PreToolUse", "PostToolUse":
            // Tool activity → session is working
            return .active

        case "PostToolUseFailure":
            // Tool was interrupted or failed — treat as waiting for input
            if event.is_interrupt {
                return .waiting_input
            }
            return current ?? .active

        case "SessionStart":
            return .active

        default:
            return current ?? .active
        }
    }

    /// Sync agents from accumulated dict in the session JSON file.
    /// The hook script maintains this dict across all events, so we always have the full picture.
    private func syncAgents(from event: HookEvent, into session: inout ManagedSession) {
        // Rebuild agents from the accumulated dict written by the hook
        var updated: [String: ManagedSession.ManagedAgent] = [:]
        for (key, entry) in event.agents {
            // Skip completed agents — they should disappear from the overlay
            if entry.status == "completed" { continue }
            let displayName = !entry.agent_type.isEmpty ? entry.agent_type : entry.agent_name
            updated[key] = ManagedSession.ManagedAgent(
                agentId: entry.agent_id,
                agentName: displayName,
                agentType: entry.agent_type,
                status: .active,
                createdAt: Date(timeIntervalSince1970: entry.started_at),
                updatedAt: Date(timeIntervalSince1970: event.timestamp)
            )
        }
        session.agents = updated
    }

    // MARK: - Publishing

    private func publishSessions() {
        sessions = managedSessions.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { managed in
                Session(
                    id: managed.sessionId,
                    session_id: managed.sessionId,
                    project_name: managed.projectName,
                    project_path: managed.projectPath,
                    status: managed.status,
                    created_at: managed.createdAt,
                    updated_at: managed.updatedAt,
                    agents: managed.agents.values
                        .sorted { $0.createdAt < $1.createdAt }
                        .map { agent in
                            Agent(
                                id: "\(managed.sessionId)-\(agent.agentId)",
                                session_id: managed.sessionId,
                                agent_name: agent.agentName,
                                agent_type: agent.agentType,
                                status: agent.status,
                                created_at: agent.createdAt,
                                updated_at: agent.updatedAt
                            )
                        },
                    transcript_path: managed.transcriptPath,
                    user_prompt: managed.userPrompt,
                    tty: managed.tty
                )
            }
    }
}
