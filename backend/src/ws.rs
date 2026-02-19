use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::Response,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::broadcast;
use tracing::{info, warn};

use crate::api::AppState;

pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sender, mut receiver) = socket.split();

    // Send current sessions immediately on connect.
    match crate::db::get_active_sessions(&state.pool).await {
        Ok(sessions) => {
            if let Ok(json) = serde_json::to_string(&sessions) {
                if sender.send(Message::Text(json)).await.is_err() {
                    return;
                }
            }
        }
        Err(e) => warn!("Failed to fetch sessions for new WS client: {e}"),
    }

    let mut rx = state.tx.subscribe();

    // Forward broadcast messages to the WebSocket client.
    let send_task = tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(msg) => {
                    if sender.send(Message::Text(msg)).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    warn!("WS client lagged by {n} messages");
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    // Drain incoming frames (ping/pong/close) until the client disconnects.
    while let Some(Ok(_)) = receiver.next().await {}

    send_task.abort();
    info!("WebSocket client disconnected");
}
