use rand::seq::SliceRandom;
use rand::thread_rng;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub enum Suit {
    #[serde(rename = "♠")]
    Spades,
    #[serde(rename = "♥")]
    Hearts,
    #[serde(rename = "♦")]
    Diamonds,
    #[serde(rename = "♣")]
    Clubs,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Card {
    pub rank: String,
    pub suit: Suit,
}

impl Card {
    pub fn value(&self) -> u8 {
        match self.rank.as_str() {
            "A" => 11,
            "K" | "Q" | "J" => 10,
            n => n.parse().unwrap_or(0),
        }
    }

    pub fn is_ace(&self) -> bool {
        self.rank == "A"
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Hand {
    pub cards: Vec<Card>,
}

impl Hand {
    pub fn new() -> Self {
        Hand { cards: Vec::new() }
    }

    pub fn add_card(&mut self, card: Card) {
        self.cards.push(card);
    }

    pub fn total(&self) -> u8 {
        let mut sum: u16 = 0;
        let mut aces: u8 = 0;

        for card in &self.cards {
            sum += card.value() as u16;
            if card.is_ace() {
                aces += 1;
            }
        }

        while sum > 21 && aces > 0 {
            sum -= 10;
            aces -= 1;
        }

        sum.min(255) as u8
    }

    pub fn is_soft(&self) -> bool {
        let mut sum: u16 = 0;
        let mut aces: u8 = 0;

        for card in &self.cards {
            sum += card.value() as u16;
            if card.is_ace() {
                aces += 1;
            }
        }

        while sum > 21 && aces > 1 {
            sum -= 10;
            aces -= 1;
        }

        aces > 0 && sum <= 21
    }

    pub fn is_busted(&self) -> bool {
        self.total() > 21
    }

    pub fn is_blackjack(&self) -> bool {
        self.cards.len() == 2 && self.total() == 21
    }
}

pub struct Shoe {
    cards: Vec<Card>,
}

impl Shoe {
    pub fn new(num_decks: u8) -> Self {
        let mut cards = Vec::new();
        let ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"];
        let suits = [Suit::Spades, Suit::Hearts, Suit::Diamonds, Suit::Clubs];

        for _ in 0..num_decks {
            for suit in &suits {
                for rank in &ranks {
                    cards.push(Card {
                        rank: rank.to_string(),
                        suit: suit.clone(),
                    });
                }
            }
        }

        let mut shoe = Shoe { cards };
        shoe.shuffle();
        shoe
    }

    pub fn shuffle(&mut self) {
        self.cards.shuffle(&mut thread_rng());
    }

    pub fn draw(&mut self) -> Card {
        if self.cards.is_empty() {
            let mut new_shoe = Shoe::new(6);
            new_shoe.shuffle();
            self.cards = new_shoe.cards;
        }
        self.cards.pop().unwrap()
    }

    pub fn needs_reshuffle(&self) -> bool {
        self.cards.len() < 60
    }

    pub fn remaining(&self) -> usize {
        self.cards.len()
    }
}

pub fn dealer_play(shoe: &mut Shoe, dealer_hand: &mut Hand) {
    while dealer_hand.total() < 17 {
        let card = shoe.draw();
        dealer_hand.add_card(card);
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub enum GameResult {
    #[serde(rename = "playing")]
    Playing,
    #[serde(rename = "player_bust")]
    PlayerBust,
    #[serde(rename = "dealer_bust")]
    DealerBust,
    #[serde(rename = "player_wins")]
    PlayerWins,
    #[serde(rename = "dealer_wins")]
    DealerWins,
    #[serde(rename = "push")]
    Push,
    #[serde(rename = "blackjack")]
    Blackjack,
}

pub fn determine_result(player: &Hand, dealer: &Hand) -> GameResult {
    if player.is_busted() {
        return GameResult::PlayerBust;
    }
    if player.is_blackjack() && !dealer.is_blackjack() {
        return GameResult::Blackjack;
    }
    if dealer.is_busted() {
        return GameResult::DealerBust;
    }
    if player.is_blackjack() && dealer.is_blackjack() {
        return GameResult::Push;
    }

    let player_total = player.total();
    let dealer_total = dealer.total();

    if player_total > dealer_total {
        GameResult::PlayerWins
    } else if dealer_total > player_total {
        GameResult::DealerWins
    } else {
        GameResult::Push
    }
}
