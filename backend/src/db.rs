use anyhow::Result;
use chrono::Utc;
use sqlx::{Row, SqlitePool};
use uuid::Uuid;

use crate::models::{Agent, SessionWithAgents};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    session_id TEXT UNIQUE NOT NULL,
    project_path TEXT NOT NULL DEFAULT '',
    project_name TEXT NOT NULL DEFAULT 'unknown',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    agent_name TEXT NOT NULL DEFAULT 'main',
    parent_session_id TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (session_id, agent_name),
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    agent_name TEXT,
    event_type TEXT NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    timestamp TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_status ON sessions(status);
CREATE INDEX IF NOT EXISTS idx_agents_session_id ON agents(session_id);
CREATE INDEX IF NOT EXISTS idx_events_session_id ON events(session_id);
"#;

pub async fn init_db(pool: &SqlitePool) -> Result<()> {
    // sqlx::query does not support multiple statements; split and execute each.
    for statement in SCHEMA.split(';') {
        let trimmed = statement.trim();
        if trimmed.is_empty() {
            continue;
        }
        sqlx::query(trimmed).execute(pool).await?;
    }
    Ok(())
}

pub async fn upsert_session(
    pool: &SqlitePool,
    session_id: &str,
    project_path: &str,
    project_name: &str,
    status: &str,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let id = Uuid::new_v4().to_string();

    sqlx::query(
        r#"
        INSERT INTO sessions (id, session_id, project_path, project_name, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            project_path = excluded.project_path,
            project_name = excluded.project_name,
            status = excluded.status,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&id)
    .bind(session_id)
    .bind(project_path)
    .bind(project_name)
    .bind(status)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn upsert_agent(
    pool: &SqlitePool,
    session_id: &str,
    agent_name: &str,
    parent_session_id: Option<&str>,
    status: &str,
) -> Result<()> {
    let now = Utc::now().to_rfc3339();
    let id = Uuid::new_v4().to_string();

    sqlx::query(
        r#"
        INSERT INTO agents (id, session_id, agent_name, parent_session_id, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, agent_name) DO UPDATE SET
            parent_session_id = excluded.parent_session_id,
            status = excluded.status,
            updated_at = excluded.updated_at
        "#,
    )
    .bind(&id)
    .bind(session_id)
    .bind(agent_name)
    .bind(parent_session_id)
    .bind(status)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn insert_event(
    pool: &SqlitePool,
    session_id: &str,
    agent_name: Option<&str>,
    event_type: &str,
    payload: &str,
) -> Result<()> {
    let id = Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        r#"
        INSERT INTO events (id, session_id, agent_name, event_type, payload, timestamp)
        VALUES (?, ?, ?, ?, ?, ?)
        "#,
    )
    .bind(&id)
    .bind(session_id)
    .bind(agent_name)
    .bind(event_type)
    .bind(payload)
    .bind(&now)
    .execute(pool)
    .await?;

    Ok(())
}

pub async fn get_active_sessions(pool: &SqlitePool) -> Result<Vec<SessionWithAgents>> {
    let rows = sqlx::query(
        r#"
        SELECT id, session_id, project_path, project_name, status, created_at, updated_at
        FROM sessions
        WHERE status != 'completed'
        ORDER BY created_at DESC
        "#,
    )
    .fetch_all(pool)
    .await?;

    let mut sessions = Vec::with_capacity(rows.len());
    for row in rows {
        let session_id: String = row.get("session_id");
        let agents = get_agents_for_session(pool, &session_id).await?;

        let id_str: String = row.get("id");
        let created_at_str: String = row.get("created_at");
        let updated_at_str: String = row.get("updated_at");

        let session = SessionWithAgents {
            id: id_str.parse().unwrap_or_else(|_| Uuid::new_v4()),
            session_id,
            project_name: row.get("project_name"),
            project_path: row.get("project_path"),
            status: row.get("status"),
            created_at: created_at_str.parse().unwrap_or_else(|_| Utc::now()),
            updated_at: updated_at_str.parse().unwrap_or_else(|_| Utc::now()),
            agents,
        };
        sessions.push(session);
    }

    Ok(sessions)
}

async fn get_agents_for_session(pool: &SqlitePool, session_id: &str) -> Result<Vec<Agent>> {
    let rows = sqlx::query(
        r#"
        SELECT id, session_id, agent_name, parent_session_id, status, created_at, updated_at
        FROM agents
        WHERE session_id = ?
        ORDER BY created_at ASC
        "#,
    )
    .bind(session_id)
    .fetch_all(pool)
    .await?;

    let agents = rows
        .iter()
        .map(|row| {
            let id_str: String = row.get("id");
            let created_at_str: String = row.get("created_at");
            let updated_at_str: String = row.get("updated_at");

            Agent {
                id: id_str.parse().unwrap_or_else(|_| Uuid::new_v4()),
                session_id: row.get("session_id"),
                agent_name: row.get("agent_name"),
                parent_session_id: row.get("parent_session_id"),
                status: row.get("status"),
                created_at: created_at_str.parse().unwrap_or_else(|_| Utc::now()),
                updated_at: updated_at_str.parse().unwrap_or_else(|_| Utc::now()),
            }
        })
        .collect();

    Ok(agents)
}

pub async fn mark_session_completed(pool: &SqlitePool, session_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        r#"
        UPDATE sessions SET status = 'completed', updated_at = ?
        WHERE session_id = ?
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        UPDATE agents SET status = 'completed', updated_at = ?
        WHERE session_id = ?
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Move 'active' → 'idle' when Claude finishes a turn.
/// Idle sessions stay visible until the user explicitly clears them.
/// 'waiting_input' and 'needs_permission' sessions are left untouched.
pub async fn mark_active_session_idle(pool: &SqlitePool, session_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        r#"
        UPDATE sessions SET status = 'idle', updated_at = ?
        WHERE session_id = ? AND status = 'active'
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        UPDATE agents SET status = 'idle', updated_at = ?
        WHERE session_id = ? AND status = 'active'
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Mark a session completed ONLY if it is currently 'active'.
/// Sessions in 'waiting_input' or 'needs_permission' state are left untouched
/// so they remain visible in the overlay until the user acknowledges them.
pub async fn mark_active_session_completed(pool: &SqlitePool, session_id: &str) -> Result<()> {
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        r#"
        UPDATE sessions SET status = 'completed', updated_at = ?
        WHERE session_id = ? AND status = 'active'
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    // Only complete agents for the session if the session was actually moved to completed.
    sqlx::query(
        r#"
        UPDATE agents SET status = 'completed', updated_at = ?
        WHERE session_id = ? AND status = 'active'
        "#,
    )
    .bind(&now)
    .bind(session_id)
    .execute(pool)
    .await?;

    Ok(())
}

/// Delete all rows from sessions, agents, events — but keep the tables intact.
pub async fn clear_all_sessions(pool: &SqlitePool) -> Result<()> {
    // Order matters: agents and events reference sessions via session_id.
    sqlx::query("DELETE FROM events").execute(pool).await?;
    sqlx::query("DELETE FROM agents").execute(pool).await?;
    sqlx::query("DELETE FROM sessions").execute(pool).await?;
    Ok(())
}

pub async fn cleanup_old_completed(pool: &SqlitePool) -> Result<()> {
    // RFC3339 strings stored in SQLite are sortable; sqlite's datetime() understands ISO-8601.
    sqlx::query(
        r#"
        DELETE FROM agents WHERE session_id IN (
            SELECT session_id FROM sessions
            WHERE status = 'completed'
            AND datetime(updated_at) <= datetime('now', '-60 seconds')
        )
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        DELETE FROM events WHERE session_id IN (
            SELECT session_id FROM sessions
            WHERE status = 'completed'
            AND datetime(updated_at) <= datetime('now', '-60 seconds')
        )
        "#,
    )
    .execute(pool)
    .await?;

    sqlx::query(
        r#"
        DELETE FROM sessions
        WHERE status = 'completed'
        AND datetime(updated_at) <= datetime('now', '-60 seconds')
        "#,
    )
    .execute(pool)
    .await?;

    Ok(())
}
