use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
};

use anyhow::Result;
use axum::{
    body::Body,
    extract::{ws::WebSocketUpgrade, Json, Path as AxumPath, State},
    http::{header, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Router,
};
use serde::{Deserialize, Serialize};
use tokio::{
    fs,
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
    base_dir: Option<String>,
    html: Arc<str>,
    version: u64,
}

#[derive(Debug, Deserialize, PartialEq, Eq)]
struct UpdateRequest {
    markdown: String,
    base_dir: Option<String>,
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
        let html = Arc::<str>::from(markdown::render("", None));
        let (events, _) = broadcast::channel(128);

        Self {
            document: RwLock::new(DocumentState {
                markdown: String::new(),
                base_dir: None,
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

    async fn apply_markdown_update(&self, request: UpdateRequest) -> UpdateOutcome {
        {
            let document = self.document.read().await;
            if document.markdown == request.markdown && document.base_dir == request.base_dir {
                return UpdateOutcome::Unchanged;
            }
        }

        let html = Arc::<str>::from(markdown::render(
            &request.markdown,
            request.base_dir.as_deref().map(Path::new),
        ));

        let version = {
            let mut document = self.document.write().await;
            if document.markdown == request.markdown && document.base_dir == request.base_dir {
                return UpdateOutcome::Unchanged;
            }

            document.markdown = request.markdown;
            document.base_dir = request.base_dir;
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
            document.base_dir = None;
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
        .route("/__md_tool/file/{encoded_path}", get(local_file))
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
        protocol_version: 3,
        features: &["render", "scroll", "close", "local_file_assets"],
    })
}

async fn update(
    State(state): State<SharedState>,
    Json(request): Json<UpdateRequest>,
) -> impl IntoResponse {
    match state.apply_markdown_update(request).await {
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

async fn local_file(AxumPath(encoded_path): AxumPath<String>) -> Response {
    let Some(path) = decode_hex_path(&encoded_path).map(PathBuf::from) else {
        return StatusCode::BAD_REQUEST.into_response();
    };

    let metadata = match fs::metadata(&path).await {
        Ok(metadata) if metadata.is_file() => metadata,
        _ => return StatusCode::NOT_FOUND.into_response(),
    };

    let bytes = match fs::read(&path).await {
        Ok(bytes) => bytes,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };

    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = StatusCode::OK;

    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(content_type_for_path(&path)),
    );
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&metadata.len().to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("0")),
    );

    response
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

fn decode_hex_path(value: &str) -> Option<String> {
    if value.len() % 2 != 0 {
        return None;
    }

    let mut bytes = Vec::with_capacity(value.len() / 2);
    let mut index = 0;
    while index < value.len() {
        let next = index + 2;
        let byte = u8::from_str_radix(&value[index..next], 16).ok()?;
        bytes.push(byte);
        index = next;
    }

    String::from_utf8(bytes).ok()
}

fn content_type_for_path(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("");

    if extension.eq_ignore_ascii_case("png") {
        return "image/png";
    }
    if extension.eq_ignore_ascii_case("jpg") || extension.eq_ignore_ascii_case("jpeg") {
        return "image/jpeg";
    }
    if extension.eq_ignore_ascii_case("gif") {
        return "image/gif";
    }
    if extension.eq_ignore_ascii_case("webp") {
        return "image/webp";
    }
    if extension.eq_ignore_ascii_case("svg") {
        return "image/svg+xml";
    }
    if extension.eq_ignore_ascii_case("bmp") {
        return "image/bmp";
    }
    if extension.eq_ignore_ascii_case("ico") {
        return "image/x-icon";
    }
    if extension.eq_ignore_ascii_case("tif") || extension.eq_ignore_ascii_case("tiff") {
        return "image/tiff";
    }
    if extension.eq_ignore_ascii_case("avif") {
        return "image/avif";
    }

    "application/octet-stream"
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
