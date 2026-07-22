# Redact

Paste log output or terminal text and get a sanitized copy: IPs become `1.2.3.4`,
domains become `example.com`, and `*.teleport.sh` tenant hostnames become
`example.teleport.sh`. Well-known public domains (github.com, goteleport.com, …)
and `file.ext:line` code references are left untouched.

All redaction happens client-side in the browser — no text ever leaves the page.

Hosted on GitHub Pages: https://geekvoice408.github.io/vibes/redact/

Previously ran as a Rust (axum) service on the homelab cluster; the redaction
logic in [redact.js](redact.js) is a direct port of that implementation,
including its test suite.

## Tests

```
node --test
```
