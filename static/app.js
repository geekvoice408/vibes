let sessionId = localStorage.getItem('blackjack_session');
let currentBet = 50;
let gameState = 'betting'; // betting | playing | result

const $ = id => document.getElementById(id);

function setBet(amount) {
    currentBet = amount;
    $('bet-amount').textContent = `$${amount}`;
    document.querySelectorAll('.chip').forEach(c => c.classList.remove('active'));
    document.querySelector(`.chip-${amount}`).classList.add('active');
}

async function doDeal() {
    const endpoint = sessionId ? '/api/deal' : '/api/new';
    const body = sessionId
        ? { session_id: sessionId, bet: currentBet }
        : { bet: currentBet };

    try {
        const res = await fetch(endpoint, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });

        if (!res.ok) {
            if (res.status === 404) {
                sessionId = null;
                localStorage.removeItem('blackjack_session');
                return doDeal();
            }
            return;
        }

        const data = await res.json();
        sessionId = data.session_id;
        localStorage.setItem('blackjack_session', sessionId);
        renderGame(data, true);
    } catch (e) {
        console.error('Deal failed:', e);
    }
}

async function doHit() {
    if (gameState !== 'playing') return;
    disableActions();

    try {
        const res = await fetch('/api/hit', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ session_id: sessionId }),
        });
        const data = await res.json();
        renderGame(data, false);
    } catch (e) {
        console.error('Hit failed:', e);
        enableActions();
    }
}

async function doStand() {
    if (gameState !== 'playing') return;
    disableActions();

    try {
        const res = await fetch('/api/stand', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ session_id: sessionId }),
        });
        const data = await res.json();
        renderGame(data, false);
    } catch (e) {
        console.error('Stand failed:', e);
        enableActions();
    }
}

async function doDouble() {
    if (gameState !== 'playing') return;
    disableActions();

    try {
        const res = await fetch('/api/double', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ session_id: sessionId }),
        });
        const data = await res.json();
        renderGame(data, false);
    } catch (e) {
        console.error('Double failed:', e);
        enableActions();
    }
}

function renderGame(data, isNewDeal) {
    updateBalance(data.balance);
    renderCards('player-cards', data.player_cards, isNewDeal);
    renderDealerCards(data, isNewDeal);
    updateTotals(data);

    if (data.status === 'playing') {
        gameState = 'playing';
        showActions();
        $('btn-double').disabled = !data.can_double;
        hideResult();
    } else {
        gameState = 'result';
        hideActions();
        showResult(data.status);
        setTimeout(() => showBetting(), 2000);
    }
}

function renderCards(containerId, cards, animate) {
    const container = $(containerId);
    container.innerHTML = '';

    cards.forEach((card, i) => {
        const el = createCardElement(card);
        if (animate) {
            el.style.animationDelay = `${i * 0.15}s`;
        } else if (i === cards.length - 1) {
            el.style.animationDelay = '0s';
        } else {
            el.style.animation = 'none';
        }
        container.appendChild(el);
    });
}

function renderDealerCards(data, isNewDeal) {
    const container = $('dealer-cards');
    container.innerHTML = '';

    data.dealer_cards.forEach((card, i) => {
        const el = createCardElement(card);
        if (isNewDeal) {
            el.style.animationDelay = `${(i + 2) * 0.15}s`;
        } else {
            el.style.animation = 'none';
        }
        container.appendChild(el);
    });

    if (data.status === 'playing' && data.dealer_cards.length === 1) {
        const hidden = document.createElement('div');
        hidden.className = 'card-hidden';
        if (isNewDeal) {
            hidden.style.animationDelay = '0.45s';
        }
        container.appendChild(hidden);
    }
}

function createCardElement(card) {
    const isRed = card.suit === '♥' || card.suit === '♦';
    const colorClass = isRed ? 'red' : 'black';

    const el = document.createElement('div');
    el.className = `card ${colorClass}`;
    el.innerHTML = `
        <div class="card-face">
            <div class="card-corner top">
                <span class="card-rank">${card.rank}</span>
                <span class="card-suit">${card.suit}</span>
            </div>
            <span class="card-center">${card.suit}</span>
            <div class="card-corner bottom">
                <span class="card-rank">${card.rank}</span>
                <span class="card-suit">${card.suit}</span>
            </div>
        </div>
    `;
    return el;
}

function updateBalance(balance) {
    const el = $('balance');
    const current = parseInt(el.textContent.replace('$', ''));
    if (current !== balance) {
        animateNumber(el, current, balance);
    }
}

function animateNumber(el, from, to) {
    const duration = 400;
    const start = performance.now();

    function tick(now) {
        const progress = Math.min((now - start) / duration, 1);
        const eased = 1 - Math.pow(1 - progress, 3);
        const value = Math.round(from + (to - from) * eased);
        el.textContent = `$${value}`;
        if (progress < 1) requestAnimationFrame(tick);
    }

    requestAnimationFrame(tick);
}

function updateTotals(data) {
    const playerTotal = $('player-total');
    playerTotal.textContent = data.player_soft && data.player_total <= 21
        ? `${data.player_total - 10}/${data.player_total}`
        : data.player_total;

    const dealerTotal = $('dealer-total');
    if (data.dealer_total !== null) {
        dealerTotal.textContent = data.dealer_total;
    } else {
        dealerTotal.textContent = data.dealer_cards[0] ? cardValue(data.dealer_cards[0]) : '';
    }
}

function cardValue(card) {
    if (card.rank === 'A') return '11';
    if (['K', 'Q', 'J'].includes(card.rank)) return '10';
    return card.rank;
}

function showActions() {
    $('actions').classList.remove('hidden');
    $('betting-area').classList.add('hidden');
    enableActions();
}

function hideActions() {
    $('actions').classList.add('hidden');
}

function showBetting() {
    $('betting-area').classList.remove('hidden');
    gameState = 'betting';
}

function disableActions() {
    $('btn-hit').disabled = true;
    $('btn-stand').disabled = true;
    $('btn-double').disabled = true;
}

function enableActions() {
    $('btn-hit').disabled = false;
    $('btn-stand').disabled = false;
}

function showResult(status) {
    const el = $('result-text');
    const messages = {
        'blackjack': { text: 'Blackjack!', class: 'win' },
        'player_wins': { text: 'You Win!', class: 'win' },
        'dealer_bust': { text: 'Dealer Busts!', class: 'win' },
        'player_bust': { text: 'Bust!', class: 'lose' },
        'dealer_wins': { text: 'Dealer Wins', class: 'lose' },
        'push': { text: 'Push', class: 'push' },
    };

    const msg = messages[status] || { text: status, class: 'push' };
    el.textContent = msg.text;
    el.className = `result-text show ${msg.class}`;
}

function hideResult() {
    const el = $('result-text');
    el.className = 'result-text';
}

// Restore session on load
async function init() {
    if (sessionId) {
        try {
            const res = await fetch(`/api/state/${sessionId}`);
            if (res.ok) {
                const data = await res.json();
                if (data.status !== 'playing') {
                    gameState = 'betting';
                    updateBalance(data.balance);
                } else {
                    renderGame(data, false);
                }
            } else {
                sessionId = null;
                localStorage.removeItem('blackjack_session');
            }
        } catch (e) {
            sessionId = null;
            localStorage.removeItem('blackjack_session');
        }
    }
}

init();
