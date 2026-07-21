use axum::{routing::post, Json, Router};
use regex::Regex;
use serde::{Deserialize, Serialize};
use tower_http::services::ServeDir;

#[derive(Deserialize)]
struct RedactRequest {
    text: String,
}

#[derive(Serialize)]
struct RedactResponse {
    redacted: String,
    ip_count: usize,
    domain_count: usize,
}

// Well-known domains that are safe to leave in place. Exact match or any
// subdomain of these is preserved. Deliberately does NOT include teleport.sh:
// *.teleport.sh subdomains are customer tenants and must be redacted.
const ALLOWED_DOMAINS: &[&str] = &[
    "example.com",
    "github.com",
    "gitlab.com",
    "google.com",
    "goteleport.com",
    "docker.io",
    "ghcr.io",
    "quay.io",
    "kubernetes.io",
    "k8s.io",
    "example.teleport.sh",
];

// Source-file extensions that show up as `file.ext:line` references in logs.
// "sh" is intentionally absent — it would collide with *.teleport.sh domains.
const CODE_EXTENSIONS: &[&str] = &[
    "go", "rs", "py", "js", "ts", "tsx", "jsx", "java", "rb", "php", "c", "h", "cc", "cpp",
    "hpp", "cs", "css", "html", "json", "yaml", "yml", "toml", "proto", "mod", "sum", "lock",
    "md", "txt", "log",
];

fn is_allowed_domain(matched: &str) -> bool {
    let lower = matched.to_ascii_lowercase();
    ALLOWED_DOMAINS
        .iter()
        .any(|d| lower == *d || lower.ends_with(&format!(".{d}")))
}

fn is_code_reference(m: &regex::Match) -> bool {
    // file.ext where ext is a source-file extension (cli.go, state.go, app.js)
    let ext = m.as_str().rsplit('.').next().unwrap().to_ascii_lowercase();
    CODE_EXTENSIONS.contains(&ext.as_str())
}

fn placeholder_for(matched: &str) -> &'static str {
    if matched.to_ascii_lowercase().ends_with(".teleport.sh") {
        "example.teleport.sh"
    } else {
        "example.com"
    }
}

fn redact_text(input: &str) -> RedactResponse {
    let ip_re = Regex::new(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b").unwrap();
    // No trailing \b: it cannot land before '_' (a word character), which made
    // "heb-dev.teleport.sh_443" match as "heb-dev.teleport". Instead we match
    // greedily and reject matches that end mid-token below.
    let domain_re = Regex::new(
        r"(?i)\b([a-z0-9]([a-z0-9\-]*[a-z0-9])?\.)+([a-z]{2,63})",
    )
    .unwrap();

    let ip_count = ip_re.find_iter(input).count();
    let after_ips = ip_re.replace_all(input, "1.2.3.4");

    let mut domain_count = 0;
    let mut redacted = String::with_capacity(after_ips.len());
    let mut last = 0;
    for m in domain_re.find_iter(&after_ips) {
        // ends mid-token (e.g. "foo.bar123" matching as "foo.bar")? not a domain
        let ends_mid_token = after_ips[m.end()..]
            .bytes()
            .next()
            .is_some_and(|b| b.is_ascii_alphanumeric() || b == b'-');
        redacted.push_str(&after_ips[last..m.start()]);
        if ends_mid_token || is_allowed_domain(m.as_str()) || is_code_reference(&m) {
            redacted.push_str(m.as_str());
        } else {
            domain_count += 1;
            redacted.push_str(placeholder_for(m.as_str()));
        }
        last = m.end();
    }
    redacted.push_str(&after_ips[last..]);

    RedactResponse {
        redacted,
        ip_count,
        domain_count,
    }
}

async fn handle_redact(Json(req): Json<RedactRequest>) -> Json<RedactResponse> {
    Json(redact_text(&req.text))
}

#[tokio::main]
async fn main() {
    let app = Router::new()
        .route("/api/redact", post(handle_redact))
        .fallback_service(ServeDir::new("static"));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    println!("Redact running on http://localhost:8080");
    axum::serve(listener, app).await.unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_references_untouched() {
        let input = "INFO  Using Teleport identity file file:/var/lib/teleport/bot/machine-id/identity event-handler/cli.go:284";
        let r = redact_text(input);
        assert_eq!(r.redacted, input);
        assert_eq!(r.domain_count, 0);
    }

    #[test]
    fn storage_dir_tenant_redacted_code_ref_kept() {
        let input = "INFO  Using existing storage directory dir:/var/lib/teleport-event-handler/heb-dev.teleport.sh_443 event-handler/state.go:148";
        let r = redact_text(input);
        assert_eq!(
            r.redacted,
            "INFO  Using existing storage directory dir:/var/lib/teleport-event-handler/example.teleport.sh_443 event-handler/state.go:148"
        );
        assert_eq!(r.domain_count, 1);
    }

    #[test]
    fn partial_token_not_matched() {
        let r = redact_text("build id foo.bar123 unchanged");
        assert_eq!(r.redacted, "build id foo.bar123 unchanged");
        assert_eq!(r.domain_count, 0);
    }

    #[test]
    fn idempotent_on_own_output() {
        let once = redact_text("https://gsrio.teleport.sh:443 and username@gsr.io").redacted;
        let twice = redact_text(&once);
        assert_eq!(twice.redacted, once);
        assert_eq!(twice.domain_count, 0);
    }

    #[test]
    fn allowed_domains_untouched() {
        let r = redact_text("clone it from github.com or api.github.com today");
        assert_eq!(r.redacted, "clone it from github.com or api.github.com today");
        assert_eq!(r.domain_count, 0);
    }

    #[test]
    fn profile_url_redacted() {
        let r = redact_text("> Profile URL:        https://gsrio.teleport.sh:443");
        assert_eq!(r.redacted, "> Profile URL:        https://example.teleport.sh:443");
        assert_eq!(r.domain_count, 1);
    }

    #[test]
    fn email_domain_redacted() {
        let r = redact_text("Logged in as:       username@gsr.io");
        assert_eq!(r.redacted, "Logged in as:       username@example.com");
        assert_eq!(r.domain_count, 1);
    }

    #[test]
    fn ips_redacted() {
        let r = redact_text("connecting to 10.40.1.7 from host2.gsr.io");
        assert_eq!(r.redacted, "connecting to 1.2.3.4 from example.com");
        assert_eq!(r.ip_count, 1);
        assert_eq!(r.domain_count, 1);
    }
}
