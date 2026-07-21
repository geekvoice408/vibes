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

fn redact_text(input: &str) -> RedactResponse {
    let ip_re = Regex::new(r"\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b").unwrap();
    let domain_re = Regex::new(
        r"(?i)\b([a-z0-9]([a-z0-9\-]*[a-z0-9])?\.)+([a-z]{2,63})\b",
    )
    .unwrap();

    let ip_count = ip_re.find_iter(input).count();
    let after_ips = ip_re.replace_all(input, "1.2.3.4");

    let domain_count = domain_re
        .find_iter(&after_ips)
        .filter(|m| {
            let s = m.as_str();
            s != "example.com" && s != "1.2.3.4"
        })
        .count();

    let redacted = domain_re.replace_all(&after_ips, |caps: &regex::Captures| {
        let matched = caps.get(0).unwrap().as_str();
        if matched == "example.com" {
            matched.to_string()
        } else {
            "example.com".to_string()
        }
    });

    RedactResponse {
        redacted: redacted.into_owned(),
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
