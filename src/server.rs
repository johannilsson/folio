use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    http::{Response, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Json},
    routing::get,
    Router,
};
use rust_embed::RustEmbed;
use serde_json::json;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Instant,
};
use tokio::sync::broadcast;
use tower_http::cors::CorsLayer;

#[derive(RustEmbed)]
#[folder = "frontend/dist/"]
struct Assets;

#[derive(Clone)]
pub struct AppState {
    pub doc_path: PathBuf,
    pub folio_path: PathBuf,
    pub write_token: Arc<Mutex<Option<Instant>>>,
    pub tx: broadcast::Sender<String>,
    pub read_only: bool,
    pub token: Option<String>,
    pub kroki_url: String,
    pub plantuml_url: String,
}

async fn auth_middleware(
    State(state): State<AppState>,
    req: axum::http::Request<Body>,
    next: Next,
) -> impl IntoResponse {
    if let Some(expected) = &state.token {
        let auth = req
            .headers()
            .get("Authorization")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let bearer = format!("Bearer {}", expected);
        if auth != bearer {
            return (StatusCode::UNAUTHORIZED, "Unauthorized").into_response();
        }
    }
    next.run(req).await
}

async fn serve_index() -> impl IntoResponse {
    match Assets::get("index.html") {
        Some(content) => Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "text/html; charset=utf-8")
            .body(Body::from(content.data.into_owned()))
            .unwrap(),
        None => (StatusCode::NOT_FOUND, "index.html not found").into_response(),
    }
}

async fn serve_asset(axum::extract::Path(path): axum::extract::Path<String>) -> impl IntoResponse {
    let asset_path = format!("assets/{}", path);
    match Assets::get(&asset_path) {
        Some(content) => {
            let mime = mime_guess::from_path(&asset_path)
                .first_or_octet_stream()
                .to_string();
            Response::builder()
                .status(StatusCode::OK)
                .header("content-type", mime)
                .body(Body::from(content.data.into_owned()))
                .unwrap()
        }
        None => (StatusCode::NOT_FOUND, "not found").into_response(),
    }
}

async fn get_file(State(state): State<AppState>) -> impl IntoResponse {
    match tokio::fs::read_to_string(&state.doc_path).await {
        Ok(content) => (StatusCode::OK, content).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn put_file(State(state): State<AppState>, body: String) -> impl IntoResponse {
    if state.read_only {
        return (StatusCode::FORBIDDEN, "read-only mode").into_response();
    }
    *state.write_token.lock().unwrap() = Some(Instant::now());
    match tokio::fs::write(&state.doc_path, &body).await {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn get_folio(State(state): State<AppState>) -> impl IntoResponse {
    if !state.folio_path.exists() {
        return Json(json!({"version": 1, "annotations": []})).into_response();
    }
    match tokio::fs::read_to_string(&state.folio_path).await {
        Ok(content) => Response::builder()
            .status(StatusCode::OK)
            .header("content-type", "application/json")
            .body(Body::from(content))
            .unwrap(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn put_folio(State(state): State<AppState>, body: String) -> impl IntoResponse {
    match tokio::fs::write(&state.folio_path, &body).await {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}

async fn get_info(State(state): State<AppState>) -> impl IntoResponse {
    let filename = state.doc_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");
    Json(json!({ "filename": filename, "plantumlUrl": state.plantuml_url }))
}

async fn get_kroki_url(State(state): State<AppState>) -> impl IntoResponse {
    Json(json!({ "url": state.kroki_url }))
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state.tx.subscribe()))
}

async fn handle_ws(mut socket: WebSocket, mut rx: broadcast::Receiver<String>) {
    loop {
        tokio::select! {
            msg = rx.recv() => {
                match msg {
                    Ok(text) => {
                        if socket.send(Message::Text(text.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
            msg = socket.recv() => {
                if msg.is_none() {
                    break;
                }
            }
        }
    }
}

pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/", get(serve_index))
        .route("/assets/{*path}", get(serve_asset))
        .route("/api/file", get(get_file).put(put_file))
        .route("/api/folio", get(get_folio).put(put_folio))
        .route("/api/info", get(get_info))
        .route("/api/kroki-url", get(get_kroki_url))
        .route("/ws", get(ws_handler))
        .layer(middleware::from_fn_with_state(state.clone(), auth_middleware))
        .layer(CorsLayer::permissive())
        .with_state(state)
}
