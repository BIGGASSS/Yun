use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
};
use tower::ServiceExt;
use yun_server::{AppState, Config};

async fn post(app: &Router, path: &str, body: Value) -> Value {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(path)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap()
}

#[tokio::test]
async fn maximum_token_ttls_never_overflow_or_issue_expired_tokens() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::new(dir.path());
    config.access_ttl_ms = i64::MAX;
    config.refresh_ttl_ms = i64::MAX;
    let state = AppState::open(config).await.unwrap();
    yun_server::create_user(&state, "alice", "a-long-test-password")
        .await
        .unwrap();
    let app = yun_server::router(state.clone());
    let login = post(
        &app,
        "/api/v1/auth/login",
        json!({
            "username": "alice", "password": "a-long-test-password",
            "device_id": uuid::Uuid::new_v4().to_string(),
        }),
    )
    .await;
    assert_eq!(login["expires_at"], i64::MAX);
    let refreshed = post(
        &app,
        "/api/v1/auth/refresh",
        json!({
            "refresh_token": login["refresh_token"],
        }),
    )
    .await;
    assert_eq!(refreshed["expires_at"], i64::MAX);
    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/v1/library")
                .header(
                    "authorization",
                    format!("Bearer {}", refreshed["access_token"].as_str().unwrap()),
                )
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    drop(response);
    state.close().await;
}

fn create_user_with_stdin(
    data_dir: &std::path::Path,
    username: &str,
    password: &[u8],
) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_yun-server"))
        .arg("--data-dir")
        .arg(data_dir)
        .args(["create-user", username, "--password-stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(password).unwrap();
    child.wait_with_output().unwrap()
}

#[test]
fn password_stdin_rejects_a_valid_prefix_followed_by_truncated_input() {
    let dir = tempfile::tempdir().unwrap();
    let prefix = format!("{}\r\n", "a".repeat(1024));
    let oversized = format!("{prefix}unexpected password suffix");
    let output = create_user_with_stdin(dir.path(), "alice", oversized.as_bytes());
    assert!(
        !output.status.success(),
        "oversized password was silently truncated"
    );
    // Rejection must not create the account; the exact maximum plus CRLF remains valid.
    let output = create_user_with_stdin(dir.path(), "alice", prefix.as_bytes());
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
