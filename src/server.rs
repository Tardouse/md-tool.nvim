use std::{
    collections::HashSet,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};

use anyhow::Result;
use axum::{
    extract::{ws::WebSocketUpgrade, Json, State},
    http::StatusCode,
    response::{Html, IntoResponse},
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use tokio::{
    net::TcpListener,
    signal,
    sync::{broadcast, Mutex, RwLock},
};
use tracing::{debug, info};

use crate::{markdown, websocket};

const INDEX_HTML: &str = include_str!("../assets/index.html");

#[derive(Debug, Clone)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Debug)]
struct DocumentState {
    markdown: String,
    html: Arc<str>,
    version: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
pub struct ScrollState {
    pub cursor: usize,
    pub line_count: usize,
    pub winheight: usize,
    pub winline: usize,
}

#[derive(Serialize)]
struct Capabilities {
    protocol_version: u32,
    features: &'static [&'static str],
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ServerEvent<'a> {
    Close,
    Render {
        html: &'a str,
    },
    Scroll {
        cursor: usize,
        line_count: usize,
        winheight: usize,
        winline: usize,
    },
}

#[derive(Debug)]
pub enum UpdateOutcome {
    Unchanged,
    Updated {
        html_len: usize,
        version: u64,
        clients: usize,
    },
}

#[derive(Debug)]
pub enum ScrollOutcome {
    Unchanged,
    Updated { clients: usize },
}

#[derive(Debug)]
pub struct AppState {
    document: RwLock<DocumentState>,
    events: broadcast::Sender<Arc<str>>,
    scroll: RwLock<Option<ScrollState>>,
    clients: Mutex<HashSet<usize>>,
    next_client_id: AtomicUsize,
}

pub type SharedState = Arc<AppState>;

impl AppState {
    fn new() -> Self {
        let html = Arc::<str>::from(markdown::render(""));
        let (events, _) = broadcast::channel(128);

        Self {
            document: RwLock::new(DocumentState {
                markdown: String::new(),
                html,
                version: 0,
            }),
            events,
            scroll: RwLock::new(None),
            clients: Mutex::new(HashSet::new()),
            next_client_id: AtomicUsize::new(1),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Arc<str>> {
        self.events.subscribe()
    }

    pub async fn register_client(&self) -> usize {
        let client_id = self.next_client_id.fetch_add(1, Ordering::Relaxed);
        self.clients.lock().await.insert(client_id);
        client_id
    }

    pub async fn unregister_client(&self, client_id: usize) {
        self.clients.lock().await.remove(&client_id);
    }

    pub async fn client_count(&self) -> usize {
        self.clients.lock().await.len()
    }

    pub async fn current_html(&self) -> Arc<str> {
        self.document.read().await.html.clone()
    }

    pub async fn current_render_event(&self) -> Arc<str> {
        let html = self.current_html().await;
        encode_event(ServerEvent::Render {
            html: html.as_ref(),
        })
    }

    pub async fn current_scroll_event(&self) -> Option<Arc<str>> {
        self.scroll.read().await.as_ref().copied().map(scroll_event)
    }

    pub async fn apply_markdown_update(&self, markdown_input: String) -> UpdateOutcome {
        {
            let document = self.document.read().await;
            if document.markdown == markdown_input {
                return UpdateOutcome::Unchanged;
            }
        }

        let html = Arc::<str>::from(markdown::render(&markdown_input));

        let version = {
            let mut document = self.document.write().await;
            if document.markdown == markdown_input {
                return UpdateOutcome::Unchanged;
            }

            document.markdown = markdown_input;
            document.html = html.clone();
            document.version += 1;
            document.version
        };

        self.broadcast(encode_event(ServerEvent::Render {
            html: html.as_ref(),
        }));
        let clients = self.client_count().await;

        UpdateOutcome::Updated {
            html_len: html.len(),
            version,
            clients,
        }
    }

    pub async fn apply_scroll_update(&self, scroll: ScrollState) -> ScrollOutcome {
        let mut current = self.scroll.write().await;
        if current.as_ref() == Some(&scroll) {
            return ScrollOutcome::Unchanged;
        }

        *current = Some(scroll);
        drop(current);

        self.broadcast(scroll_event(scroll));
        let clients = self.client_count().await;

        ScrollOutcome::Updated { clients }
    }

    pub async fn close_preview(&self) -> usize {
        {
            let mut document = self.document.write().await;
            document.markdown.clear();
            document.html = Arc::<str>::from("");
            document.version += 1;
        }
        *self.scroll.write().await = None;

        self.broadcast(encode_event(ServerEvent::Render { html: "" }));
        self.broadcast(encode_event(ServerEvent::Close));
        self.client_count().await
    }

    fn broadcast(&self, event: Arc<str>) {
        let _ = self.events.send(event);
    }
}

pub async fn run(config: ServerConfig) -> Result<()> {
    let address = format!("{}:{}", config.host, config.port);
    let listener = TcpListener::bind(&address).await?;
    let state = Arc::new(AppState::new());
    let app = app(state);

    info!(address = %address, "preview server listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    info!("preview server stopped");
    Ok(())
}

fn app(state: SharedState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/health", get(health))
        .route("/capabilities", get(capabilities))
        .route("/close", post(close_preview))
        .route("/scroll", post(scroll))
        .route("/update", post(update))
        .route("/ws", get(websocket_upgrade))
        .with_state(state)
}

async fn index() -> Html<&'static str> {
    Html(INDEX_HTML)
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn capabilities() -> Json<Capabilities> {
    Json(Capabilities {
        protocol_version: 2,
        features: &["render", "scroll", "close"],
    })
}

async fn update(State(state): State<SharedState>, markdown_input: String) -> impl IntoResponse {
    match state.apply_markdown_update(markdown_input).await {
        UpdateOutcome::Unchanged => {
            debug!("skipped unchanged markdown update");
            StatusCode::NO_CONTENT
        }
        UpdateOutcome::Updated {
            html_len,
            version,
            clients,
        } => {
            info!(version, html_len, clients, "broadcasted markdown update");
            StatusCode::OK
        }
    }
}

async fn scroll(
    State(state): State<SharedState>,
    Json(scroll): Json<ScrollState>,
) -> impl IntoResponse {
    match state.apply_scroll_update(scroll).await {
        ScrollOutcome::Unchanged => StatusCode::NO_CONTENT,
        ScrollOutcome::Updated { clients } => {
            debug!(clients, ?scroll, "broadcasted scroll update");
            StatusCode::OK
        }
    }
}

async fn close_preview(State(state): State<SharedState>) -> impl IntoResponse {
    let clients = state.close_preview().await;
    info!(clients, "broadcasted preview close");
    StatusCode::NO_CONTENT
}

async fn websocket_upgrade(
    ws: WebSocketUpgrade,
    State(state): State<SharedState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| websocket::handle_socket(state, socket))
}

fn encode_event(event: ServerEvent<'_>) -> Arc<str> {
    Arc::<str>::from(serde_json::to_string(&event).expect("failed to serialize preview event"))
}

fn scroll_event(scroll: ScrollState) -> Arc<str> {
    encode_event(ServerEvent::Scroll {
        cursor: scroll.cursor,
        line_count: scroll.line_count,
        winheight: scroll.winheight,
        winline: scroll.winline,
    })
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{signal, SignalKind};

        let mut stream =
            signal(SignalKind::terminate()).expect("failed to install SIGTERM handler");
        stream.recv().await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }

    info!("shutdown signal received");
}
