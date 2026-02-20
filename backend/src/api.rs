use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde_json::json;
use tokio::sync::broadcast;
use tracing::{info, warn};

use crate::{
    db,
    models::{HealthResponse, HookEvent},
};

#[derive(Clone)]
pub struct AppState {
    pub pool: sqlx::SqlitePool,
    pub tx: broadcast::Sender<String>,
}

impl AppState {
    pub fn new(pool: sqlx::SqlitePool, tx: broadcast::Sender<String>) -> Self {
        Self { pool, tx }
    }

    /// Fetch active sessions and broadcast to all WS clients.
    pub async fn broadcast_sessions(&self) {
        match db::get_active_sessions(&self.pool).await {
            Ok(sessions) => match serde_json::to_string(&sessions) {
                Ok(json) => {
                    // Ignore the error: it means no receivers are connected.
                    let _ = self.tx.send(json);
                }
                Err(e) => warn!("Failed to serialize sessions: {e}"),
            },
            Err(e) => warn!("Failed to fetch sessions for broadcast: {e}"),
        }
    }
}

pub async fn health() -> impl IntoResponse {
    Json(HealthResponse {
        status: "ok",
        version: "0.1.0",
    })
}

pub async fn get_sessions(State(state): State<AppState>) -> impl IntoResponse {
    match db::get_active_sessions(&state.pool).await {
        Ok(sessions) => Json(sessions).into_response(),
        Err(e) => {
            warn!("get_sessions error: {e}");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": e.to_string()}))).into_response()
        }
    }
}

pub async fn post_event(
    State(state): State<AppState>,
    Json(event): Json<HookEvent>,
) -> impl IntoResponse {
    info!(
        event_type = %event.event_type,
        session_id = %event.session_id,
        "Received hook event"
    );

    let project_path = event.project_path.as_deref().unwrap_or("");
    let project_name = event.project_name.as_deref().unwrap_or("unknown");
    let agent_name = event.agent_name.as_deref().unwrap_or("main");
    let needs_input = event.needs_input.unwrap_or(false);

    // Handle stop: move 'active' sessions to 'idle' so they stay visible in the overlay.
    // Sessions in 'waiting_input' or 'needs_permission' are left untouched.
    if event.event_type == "stop" {
        if let Err(e) = db::mark_active_session_idle(&state.pool, &event.session_id).await {
            warn!("mark_active_session_idle error: {e}");
        }
        if let Err(e) = db::insert_event(&state.pool, &event.session_id, Some(agent_name), &event.event_type, "{}").await {
            warn!("insert_event error: {e}");
        }
        state.broadcast_sessions().await;
        return StatusCode::OK.into_response();
    }

    // Handle session_end: mark session completed so it's removed from the overlay.
    if event.event_type == "session_end" {
        if let Err(e) = db::mark_session_completed(&state.pool, &event.session_id).await {
            warn!("mark_session_completed error: {e}");
        }
        let _ = db::insert_event(&state.pool, &event.session_id, Some(agent_name), &event.event_type, "{}").await;
        state.broadcast_sessions().await;
        return StatusCode::OK.into_response();
    }

    let (session_status, agent_status) = match event.event_type.as_str() {
        "notification" if needs_input => ("waiting_input", "waiting_input"),
        "needs_permission" => ("needs_permission", "needs_permission"),
        "subagent_stop" => ("active", "completed"),
        _ => ("active", "active"),
    };

    // Upsert session.
    if let Err(e) = db::upsert_session(
        &state.pool,
        &event.session_id,
        project_path,
        project_name,
        session_status,
    )
    .await
    {
        warn!("upsert_session error: {e}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    // Upsert agent.
    if let Err(e) = db::upsert_agent(
        &state.pool,
        &event.session_id,
        agent_name,
        event.parent_session_id.as_deref(),
        agent_status,
    )
    .await
    {
        warn!("upsert_agent error: {e}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": e.to_string()})),
        )
            .into_response();
    }

    // Build event payload.
    let payload = serde_json::to_string(&serde_json::json!({
        "needs_input": event.needs_input,
        "tool_name": event.tool_name,
        "transcript_path": event.transcript_path,
        "message": event.message,
    }))
    .unwrap_or_else(|_| "{}".to_string());

    if let Err(e) = db::insert_event(
        &state.pool,
        &event.session_id,
        Some(agent_name),
        &event.event_type,
        &payload,
    )
    .await
    {
        warn!("insert_event error: {e}");
    }

    state.broadcast_sessions().await;

    StatusCode::OK.into_response()
}

pub async fn delete_session(
    State(state): State<AppState>,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    match db::mark_session_completed(&state.pool, &session_id).await {
        Ok(()) => {
            state.broadcast_sessions().await;
            StatusCode::OK.into_response()
        }
        Err(e) => {
            warn!("delete_session error: {e}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}

pub async fn clear_all_sessions(State(state): State<AppState>) -> impl IntoResponse {
    match db::clear_all_sessions(&state.pool).await {
        Ok(()) => {
            state.broadcast_sessions().await;
            StatusCode::OK.into_response()
        }
        Err(e) => {
            warn!("clear_all_sessions error: {e}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({"error": e.to_string()})),
            )
                .into_response()
        }
    }
}
