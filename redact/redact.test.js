// Ported from the Rust test suite in apps-src/redact/src/main.rs.
// Run with: node --test

const test = require('node:test');
const assert = require('node:assert');
const { redactText } = require('./redact.js');

test('code references untouched', () => {
    const input = 'INFO  Using Teleport identity file file:/var/lib/teleport/bot/machine-id/identity event-handler/cli.go:284';
    const r = redactText(input);
    assert.strictEqual(r.redacted, input);
    assert.strictEqual(r.domain_count, 0);
});

test('storage dir tenant redacted, code ref kept', () => {
    const input = 'INFO  Using existing storage directory dir:/var/lib/teleport-event-handler/heb-dev.teleport.sh_443 event-handler/state.go:148';
    const r = redactText(input);
    assert.strictEqual(
        r.redacted,
        'INFO  Using existing storage directory dir:/var/lib/teleport-event-handler/example.teleport.sh_443 event-handler/state.go:148'
    );
    assert.strictEqual(r.domain_count, 1);
});

test('partial token not matched', () => {
    const r = redactText('build id foo.bar123 unchanged');
    assert.strictEqual(r.redacted, 'build id foo.bar123 unchanged');
    assert.strictEqual(r.domain_count, 0);
});

test('idempotent on own output', () => {
    const once = redactText('https://gsrio.teleport.sh:443 and username@gsr.io').redacted;
    const twice = redactText(once);
    assert.strictEqual(twice.redacted, once);
    assert.strictEqual(twice.domain_count, 0);
});

test('allowed domains untouched', () => {
    const r = redactText('clone it from github.com or api.github.com today');
    assert.strictEqual(r.redacted, 'clone it from github.com or api.github.com today');
    assert.strictEqual(r.domain_count, 0);
});

test('profile URL redacted', () => {
    const r = redactText('> Profile URL:        https://gsrio.teleport.sh:443');
    assert.strictEqual(r.redacted, '> Profile URL:        https://example.teleport.sh:443');
    assert.strictEqual(r.domain_count, 1);
});

test('email domain redacted', () => {
    const r = redactText('Logged in as:       username@gsr.io');
    assert.strictEqual(r.redacted, 'Logged in as:       username@example.com');
    assert.strictEqual(r.domain_count, 1);
});

test('IPs redacted', () => {
    const r = redactText('connecting to 10.40.1.7 from host2.gsr.io');
    assert.strictEqual(r.redacted, 'connecting to 1.2.3.4 from example.com');
    assert.strictEqual(r.ip_count, 1);
    assert.strictEqual(r.domain_count, 1);
});
