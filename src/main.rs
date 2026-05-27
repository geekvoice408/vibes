mod api;
mod game;
mod state;

use axum::{routing::{get, post}, Router};
use std::sync::Arc;
use tower_http::services::ServeDir;

use state::AppState;

#[tokio::main]
async fn main() {
    let state = Arc::new(AppState::new());

    let api_routes = Router::new()
        .route("/new", post(api::new_game))
        .route("/hit", post(api::hit))
        .route("/stand", post(api::stand))
        .route("/double", post(api::double_down))
        .route("/deal", post(api::deal))
        .route("/state/{session_id}", get(api::get_state))
        .with_state(state);

    let app = Router::new()
        .nest("/api", api_routes)
        .fallback_service(ServeDir::new("static"));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await.unwrap();
    println!("Blackjack server running on http://localhost:3000");
    axum::serve(listener, app).await.unwrap();
}
