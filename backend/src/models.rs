use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub id: Uuid,
    pub session_id: String,
    pub project_path: String,
    pub project_name: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    pub id: Uuid,
    pub session_id: String,
    pub agent_name: String,
    pub parent_session_id: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionWithAgents {
    pub id: Uuid,
    pub session_id: String,
    pub project_name: String,
    pub project_path: String,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub agents: Vec<Agent>,
}

/// Incoming event payload from Claude CLI hooks.
#[derive(Debug, Deserialize)]
pub struct HookEvent {
    pub event_type: String,
    pub session_id: String,
    pub project_path: Option<String>,
    pub project_name: Option<String>,
    pub agent_name: Option<String>,
    pub parent_session_id: Option<String>,
    pub needs_input: Option<bool>,
    pub tool_name: Option<String>,
    pub transcript_path: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct HealthResponse {
    pub status: &'static str,
    pub version: &'static str,
}
