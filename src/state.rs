use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::game::{GameResult, Hand, Shoe};

pub struct GameSession {
    pub shoe: Shoe,
    pub player_hand: Hand,
    pub dealer_hand: Hand,
    pub balance: i64,
    pub current_bet: i64,
    pub status: GameResult,
}

impl GameSession {
    pub fn new() -> Self {
        GameSession {
            shoe: Shoe::new(6),
            player_hand: Hand::new(),
            dealer_hand: Hand::new(),
            balance: 1000,
            current_bet: 0,
            status: GameResult::Playing,
        }
    }

    pub fn deal_round(&mut self, bet: i64) {
        if self.shoe.needs_reshuffle() {
            self.shoe = Shoe::new(6);
        }

        self.current_bet = bet;
        self.balance -= bet;
        self.player_hand = Hand::new();
        self.dealer_hand = Hand::new();
        self.status = GameResult::Playing;

        self.player_hand.add_card(self.shoe.draw());
        self.dealer_hand.add_card(self.shoe.draw());
        self.player_hand.add_card(self.shoe.draw());
        self.dealer_hand.add_card(self.shoe.draw());

        if self.player_hand.is_blackjack() {
            self.status = crate::game::determine_result(&self.player_hand, &self.dealer_hand);
            self.resolve_payout();
        }
    }

    pub fn hit(&mut self) {
        if self.status != GameResult::Playing {
            return;
        }
        let card = self.shoe.draw();
        self.player_hand.add_card(card);

        if self.player_hand.is_busted() {
            self.status = GameResult::PlayerBust;
        }
    }

    pub fn stand(&mut self) {
        if self.status != GameResult::Playing {
            return;
        }
        crate::game::dealer_play(&mut self.shoe, &mut self.dealer_hand);
        self.status = crate::game::determine_result(&self.player_hand, &self.dealer_hand);
        self.resolve_payout();
    }

    pub fn double_down(&mut self) {
        if self.status != GameResult::Playing || self.player_hand.cards.len() != 2 {
            return;
        }
        self.balance -= self.current_bet;
        self.current_bet *= 2;

        let card = self.shoe.draw();
        self.player_hand.add_card(card);

        if self.player_hand.is_busted() {
            self.status = GameResult::PlayerBust;
        } else {
            crate::game::dealer_play(&mut self.shoe, &mut self.dealer_hand);
            self.status = crate::game::determine_result(&self.player_hand, &self.dealer_hand);
            self.resolve_payout();
        }
    }

    fn resolve_payout(&mut self) {
        match self.status {
            GameResult::Blackjack => {
                self.balance += self.current_bet + (self.current_bet * 3 / 2);
            }
            GameResult::PlayerWins | GameResult::DealerBust => {
                self.balance += self.current_bet * 2;
            }
            GameResult::Push => {
                self.balance += self.current_bet;
            }
            _ => {}
        }
    }
}

pub type Sessions = Arc<RwLock<HashMap<Uuid, GameSession>>>;

pub struct AppState {
    pub sessions: Sessions,
}

impl AppState {
    pub fn new() -> Self {
        AppState {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}
