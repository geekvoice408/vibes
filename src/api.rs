use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use uuid::Uuid;

use crate::game::{Card, GameResult};
use crate::state::{AppState, GameSession};

#[derive(Deserialize)]
pub struct NewGameRequest {
    bet: Option<i64>,
}

#[derive(Deserialize)]
pub struct SessionRequest {
    session_id: String,
}

#[derive(Deserialize)]
pub struct DealRequest {
    session_id: String,
    bet: i64,
}

#[derive(Serialize)]
pub struct CardResponse {
    rank: String,
    suit: String,
}

impl From<&Card> for CardResponse {
    fn from(card: &Card) -> Self {
        CardResponse {
            rank: card.rank.clone(),
            suit: serde_json::to_value(&card.suit)
                .unwrap()
                .as_str()
                .unwrap()
                .to_string(),
        }
    }
}

#[derive(Serialize)]
pub struct GameStateResponse {
    session_id: String,
    player_cards: Vec<CardResponse>,
    player_total: u8,
    player_soft: bool,
    dealer_cards: Vec<CardResponse>,
    dealer_total: Option<u8>,
    status: GameResult,
    balance: i64,
    current_bet: i64,
    can_double: bool,
}

fn build_response(session_id: &Uuid, session: &GameSession) -> GameStateResponse {
    let hide_dealer = session.status == GameResult::Playing && session.dealer_hand.cards.len() >= 2;

    let dealer_cards: Vec<CardResponse> = if hide_dealer {
        vec![CardResponse::from(&session.dealer_hand.cards[0])]
    } else {
        session.dealer_hand.cards.iter().map(CardResponse::from).collect()
    };

    let dealer_total = if hide_dealer {
        None
    } else {
        Some(session.dealer_hand.total())
    };

    GameStateResponse {
        session_id: session_id.to_string(),
        player_cards: session.player_hand.cards.iter().map(CardResponse::from).collect(),
        player_total: session.player_hand.total(),
        player_soft: session.player_hand.is_soft(),
        dealer_cards,
        dealer_total,
        status: session.status.clone(),
        balance: session.balance,
        current_bet: session.current_bet,
        can_double: session.status == GameResult::Playing && session.player_hand.cards.len() == 2 && session.balance >= session.current_bet,
    }
}

pub async fn new_game(
    State(state): State<Arc<AppState>>,
    Json(req): Json<NewGameRequest>,
) -> Json<GameStateResponse> {
    let bet = req.bet.unwrap_or(50).max(10).min(500);
    let id = Uuid::new_v4();
    let mut session = GameSession::new();
    session.deal_round(bet);

    let response = build_response(&id, &session);
    state.sessions.write().await.insert(id, session);
    Json(response)
}

pub async fn hit(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SessionRequest>,
) -> Result<Json<GameStateResponse>, StatusCode> {
    let id: Uuid = req.session_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    let mut sessions = state.sessions.write().await;
    let session = sessions.get_mut(&id).ok_or(StatusCode::NOT_FOUND)?;

    session.hit();
    Ok(Json(build_response(&id, session)))
}

pub async fn stand(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SessionRequest>,
) -> Result<Json<GameStateResponse>, StatusCode> {
    let id: Uuid = req.session_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    let mut sessions = state.sessions.write().await;
    let session = sessions.get_mut(&id).ok_or(StatusCode::NOT_FOUND)?;

    session.stand();
    Ok(Json(build_response(&id, session)))
}

pub async fn double_down(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SessionRequest>,
) -> Result<Json<GameStateResponse>, StatusCode> {
    let id: Uuid = req.session_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    let mut sessions = state.sessions.write().await;
    let session = sessions.get_mut(&id).ok_or(StatusCode::NOT_FOUND)?;

    session.double_down();
    Ok(Json(build_response(&id, session)))
}

pub async fn deal(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DealRequest>,
) -> Result<Json<GameStateResponse>, StatusCode> {
    let id: Uuid = req.session_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    let bet = req.bet.max(10).min(500);
    let mut sessions = state.sessions.write().await;
    let session = sessions.get_mut(&id).ok_or(StatusCode::NOT_FOUND)?;

    if session.balance < bet {
        return Err(StatusCode::BAD_REQUEST);
    }

    session.deal_round(bet);
    Ok(Json(build_response(&id, session)))
}

pub async fn get_state(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
) -> Result<Json<GameStateResponse>, StatusCode> {
    let id: Uuid = session_id.parse().map_err(|_| StatusCode::BAD_REQUEST)?;
    let sessions = state.sessions.read().await;
    let session = sessions.get(&id).ok_or(StatusCode::NOT_FOUND)?;

    Ok(Json(build_response(&id, session)))
}
