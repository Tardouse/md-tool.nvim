use axum::extract::ws::{Message, WebSocket};
use futures_util::{sink::SinkExt, stream::StreamExt};
use tokio::sync::broadcast;
use tracing::{debug, info};

use crate::server::SharedState;

pub async fn handle_socket(state: SharedState, socket: WebSocket) {
    let client_id = state.register_client().await;
    let mut updates = state.subscribe();
    let clients = state.client_count().await;

    info!(client_id, clients, "browser client connected");

    let (mut sender, mut receiver) = socket.split();
    let initial_render = state.current_render_event().await;

    if send_text(&mut sender, initial_render).await.is_err() {
        state.unregister_client(client_id).await;
        return;
    }
    if let Some(initial_scroll) = state.current_scroll_event().await {
        if send_text(&mut sender, initial_scroll).await.is_err() {
            state.unregister_client(client_id).await;
            return;
        }
    }

    loop {
        tokio::select! {
            update = updates.recv() => {
                match update {
                    Ok(message) => {
                        if send_text(&mut sender, message).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        debug!(client_id, skipped, "websocket client lagged behind");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
            message = receiver.next() => {
                match message {
                    Some(Ok(Message::Close(_))) => break,
                    Some(Ok(Message::Ping(payload))) => {
                        if sender.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Text(_))) => {}
                    Some(Ok(Message::Binary(_))) => {}
                    Some(Err(error)) => {
                        debug!(client_id, ?error, "websocket receive error");
                        break;
                    }
                    None => break,
                }
            }
        }
    }

    state.unregister_client(client_id).await;
    let clients = state.client_count().await;
    info!(client_id, clients, "browser client disconnected");
}

async fn send_text(
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    payload: std::sync::Arc<str>,
) -> Result<(), axum::Error> {
    sender.send(Message::Text(payload.to_string().into())).await
}
