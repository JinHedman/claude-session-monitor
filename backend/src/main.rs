mod api;
mod db;
mod models;
mod ws;

use anyhow::{Context, Result};
use axum::{
    routing::{delete, get, post},
    Router,
};
use sqlx::sqlite::{SqliteConnectOptions, SqlitePool, SqlitePoolOptions};
use std::{str::FromStr, time::Duration};
use tokio::sync::broadcast;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

use api::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "claude_monitor=info,tower_http=info".into()),
        )
        .init();

    // Resolve DB directory.
    let home = dirs::home_dir().context("could not determine home directory")?;
    let db_dir = home.join(".claude-monitor");
    std::fs::create_dir_all(&db_dir)
        .with_context(|| format!("failed to create {}", db_dir.display()))?;

    let db_path = db_dir.join("sessions.db");
    let db_url = format!("sqlite:{}", db_path.display());

    info!("Using database at {}", db_path.display());

    let connect_opts = SqliteConnectOptions::from_str(&db_url)?
        .create_if_missing(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .foreign_keys(true);

    let pool: SqlitePool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect_with(connect_opts)
        .await
        .context("failed to open SQLite database")?;

    db::init_db(&pool).await.context("failed to run schema migrations")?;

    let (tx, _rx) = broadcast::channel::<String>(100);
    let state = AppState::new(pool.clone(), tx.clone());

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/health", get(api::health))
        .route("/api/events", post(api::post_event))
        .route("/api/sessions", get(api::get_sessions).delete(api::clear_all_sessions))
        .route("/api/sessions/:session_id", delete(api::delete_session))
        .route("/ws", get(ws::ws_handler))
        .layer(cors)
        .with_state(state.clone());

    // Cleanup background task.
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(30));
        loop {
            interval.tick().await;
            match db::cleanup_old_completed(&pool).await {
                Ok(()) => state.broadcast_sessions().await,
                Err(e) => tracing::warn!("cleanup error: {e}"),
            }
        }
    });

    let listener = tokio::net::TcpListener::bind("0.0.0.0:9147")
        .await
        .context("failed to bind to port 9147")?;

    info!("Claude Monitor listening on http://0.0.0.0:9147");

    axum::serve(listener, app).await.context("server error")?;

    Ok(())
}
