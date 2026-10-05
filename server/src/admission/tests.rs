use super::*;
use crate::Config;
use axum::{Json, Router, routing::get};
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use std::time::Duration;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, DuplexStream},
    sync::{Semaphore, mpsc},
};
use tower::ServiceExt;

async fn state() -> (tempfile::TempDir, AppState) {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::open(Config::new(dir.path())).await.unwrap();
    sqlx::query("INSERT INTO users(id,username,password_hash) VALUES('u','u','unused')")
        .execute(&state.0.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO devices(user_id,id) VALUES('u','d')")
        .execute(&state.0.pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(id,user_id,device_id,access_hash,refresh_hash,access_expires,refresh_expires) VALUES('s','u','d',?,'unused',9223372036854775807,9223372036854775807)")
        .bind(hex::encode(Sha256::digest("a".repeat(64))))
        .execute(&state.0.pool).await.unwrap();
    (dir, state)
}

fn request(path: &str) -> Request {
    Request::builder()
        .uri(path)
        .header("authorization", format!("Bearer {}", "a".repeat(64)))
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn unconsumed_json_responses_hold_shared_admission_and_fail_fast() {
    let (_dir, state) = state().await;
    let app = crate::router(state.clone());
    let mut responses = Vec::new();
    // Real, serialized JSON responses, including errors and distinct routes.
    for i in 0..32 {
        let (path, status) = match i % 4 {
            0 => ("/api/v1/library?paged=true", StatusCode::OK),
            1 => ("/api/v1/stats", StatusCode::OK),
            2 => ("/missing", StatusCode::NOT_FOUND),
            // Query rejection starts as plain text, then gets replaced by the
            // error normalizer. The final JSON must retain admission too.
            _ => ("/api/v1/library?cursor=invalid", StatusCode::BAD_REQUEST),
        };
        let response = app.clone().oneshot(request(path)).await.unwrap();
        assert_eq!(response.status(), status);
        responses.push(response);
    }
    assert_eq!(state.0.requests.available_permits(), 0);
    assert_eq!(state.0.body_bytes.available_permits(), 0);
    let rejected = tokio::time::timeout(
        Duration::from_secs(1),
        crate::router(state.clone()).oneshot(request("/health")),
    )
    .await
    .expect("saturation must not queue")
    .unwrap();
    assert_eq!(rejected.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(rejected.headers()["cache-control"], "no-store");
    assert_eq!(rejected.headers()["x-content-type-options"], "nosniff");
    let error: serde_json::Value =
        serde_json::from_slice(&rejected.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(error["error"], "server capacity reached; retry later");

    // Drop returns capacity even when no body frame has ever been polled.
    drop(responses.pop());
    assert_eq!(state.0.requests.available_permits(), 1);
    let response = app.oneshot(request("/health")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.into_body().collect().await.unwrap();
    assert_eq!(state.0.requests.available_permits(), 1);
    drop(responses);
    assert_eq!(state.0.requests.available_permits(), 32);
    assert_eq!(state.0.body_bytes.available_permits(), 1024);
}

#[tokio::test]
async fn large_json_responses_charge_actual_bytes_reject_and_reclaim() {
    let (_dir, state) = state().await;
    // Serialized size is 8 MiB + 1, so each response costs 129 units, not
    // merely the 32-unit request reservation (including rounding at the edge).
    let app = Router::new()
        .route(
            "/large",
            get(|| async { Json("x".repeat(8 * 1024 * 1024 - 1)) }),
        )
        .layer(axum::middleware::from_fn_with_state(state.clone(), admit))
        .merge(crate::router(state.clone()));
    let mut responses = Vec::new();
    for i in 1..=7 {
        let response = app.clone().oneshot(request("/large")).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.body().size_hint().exact(),
            Some(8 * 1024 * 1024 + 1)
        );
        assert_eq!(state.0.body_bytes.available_permits(), 1024 - i * 129);
        responses.push(response);
    }
    assert_eq!(state.0.requests.available_permits(), 25);
    // There is room for the base request, but not its buffered JSON excess.
    let rejected = tokio::time::timeout(
        Duration::from_secs(2),
        app.clone().oneshot(request("/large")),
    )
    .await
    .expect("response-byte saturation must not queue")
    .unwrap();
    assert_eq!(rejected.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(rejected.headers()["cache-control"], "no-store");
    assert_eq!(rejected.headers()["x-content-type-options"], "nosniff");
    assert_eq!(state.0.body_bytes.available_permits(), 121 - 32);
    let error: serde_json::Value =
        serde_json::from_slice(&rejected.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(error["error"], "server capacity reached; retry later");
    assert_eq!(state.0.body_bytes.available_permits(), 121);

    // Small responses share the same budget across routers. Three fit, then
    // even request admission fails despite many free request-count slots.
    let mut small = Vec::new();
    for _ in 0..3 {
        let response = crate::router(state.clone())
            .oneshot(request("/health"))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        small.push(response);
    }
    assert_eq!(state.0.body_bytes.available_permits(), 25);
    let rejected = tokio::time::timeout(
        Duration::from_secs(1),
        app.clone().oneshot(request("/health")),
    )
    .await
    .expect("request-byte saturation must not queue")
    .unwrap();
    assert_eq!(rejected.status(), StatusCode::TOO_MANY_REQUESTS);
    drop(rejected);
    drop(small);
    assert_eq!(state.0.body_bytes.available_permits(), 121);

    // Excess permits, like base permits, follow emitted bytes and their clones
    // even after EOF and body drop, not just the unpolled response object.
    let mut body = responses.pop().unwrap().into_body();
    let bytes = body.frame().await.unwrap().unwrap().into_data().unwrap();
    assert!(body.frame().await.is_none());
    drop(body);
    let clone = bytes.slice(1..);
    drop(bytes);
    assert_eq!(state.0.body_bytes.available_permits(), 121);
    drop(clone);
    assert_eq!(state.0.body_bytes.available_permits(), 250);
    let recovered = app.oneshot(request("/large")).await.unwrap();
    assert_eq!(recovered.status(), StatusCode::OK);
    assert_eq!(state.0.body_bytes.available_permits(), 121);
    drop(recovered);
    drop(responses);
    assert_eq!(state.0.requests.available_permits(), 32);
    assert_eq!(state.0.body_bytes.available_permits(), 1024);
}

#[tokio::test]
async fn streaming_media_content_length_does_not_charge_file_size() {
    let (_dir, state) = state().await;
    let app = Router::new()
        .route(
            "/media",
            get(|| async {
                Response::builder()
                    .header(header::CONTENT_TYPE, "audio/mpeg")
                    .header(header::CONTENT_LENGTH, 1024 * 1024 * 1024)
                    .body(Body::from_stream(tokio_util::io::ReaderStream::new(
                        tokio::io::repeat(0),
                    )))
                    .unwrap()
            }),
        )
        .layer(axum::middleware::from_fn_with_state(state.clone(), admit));
    let response = app.oneshot(request("/media")).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(state.0.body_bytes.available_permits(), 1024 - 32);
    drop(response);
    assert_eq!(state.0.body_bytes.available_permits(), 1024);
    assert_eq!(state.0.requests.available_permits(), 32);
}

#[tokio::test]
async fn final_frame_and_its_clones_keep_capacity_after_body_eof_and_drop() {
    let permits = Arc::new(Semaphore::new(1));
    let mut body = with_permit(
        Body::from(r#"{"value":"buffered JSON"}"#),
        permits.clone().try_acquire_owned().unwrap(),
    );
    let frame = body.frame().await.unwrap().unwrap();
    assert!(body.is_end_stream());
    assert!(body.frame().await.is_none());
    drop(body);
    assert_eq!(permits.available_permits(), 0);
    let bytes = frame.into_data().unwrap();
    let clone = bytes.slice(1..);
    drop(bytes);
    assert_eq!(permits.available_permits(), 0);
    drop(clone);
    assert_eq!(permits.available_permits(), 1);

    // Empty responses need no transport reservation and must not leak capacity
    // when Hyper skips polling their bodies (e.g. HEAD/204).
    let _empty = with_permit(Body::empty(), permits.clone().try_acquire_owned().unwrap());
    assert_eq!(permits.available_permits(), 1);
}

struct FailedBody;
impl HttpBody for FailedBody {
    type Data = Bytes;
    type Error = std::io::Error;
    fn poll_frame(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
    ) -> Poll<Option<Result<http_body::Frame<Bytes>, Self::Error>>> {
        Poll::Ready(Some(Err(std::io::Error::other("failed stream"))))
    }
}

#[tokio::test]
async fn body_errors_return_capacity_without_waiting_for_drop() {
    let permits = Arc::new(Semaphore::new(1));
    let mut body = with_permit(
        Body::new(FailedBody),
        permits.clone().try_acquire_owned().unwrap(),
    );
    assert_eq!(permits.available_permits(), 0);
    assert!(body.frame().await.unwrap().is_err());
    assert_eq!(permits.available_permits(), 1);
}

// Exercise the production axum::serve/Hyper path with a deterministic 1 KiB
// socket buffer. Like Tokio TCP, DuplexStream supports vectored writes, so
// Hyper queues the single large JSON frame instead of copying it elsewhere.
struct MemoryListener(mpsc::Receiver<DuplexStream>);
impl axum::serve::Listener for MemoryListener {
    type Io = DuplexStream;
    type Addr = ();
    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        (self.0.recv().await.unwrap(), ())
    }
    fn local_addr(&self) -> std::io::Result<Self::Addr> {
        Ok(())
    }
}

async fn connect(
    connections: &mpsc::Sender<DuplexStream>,
    path: &str,
    status: &str,
) -> BufReader<DuplexStream> {
    let (mut client, server) = tokio::io::duplex(1024);
    assert!(tokio::io::AsyncWrite::is_write_vectored(&server));
    connections.send(server).await.unwrap();
    client
        .write_all(
            format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let mut client = BufReader::new(client);
    let mut line = String::new();
    client.read_line(&mut line).await.unwrap();
    assert!(line.starts_with(status), "{line}");
    loop {
        line.clear();
        assert_ne!(client.read_line(&mut line).await.unwrap(), 0);
        if line == "\r\n" {
            break;
        }
    }
    client
}

#[tokio::test]
async fn hyper_backpressure_keeps_json_admitted_until_write_or_disconnect() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (_dir, mut state) = state().await;
        Arc::get_mut(&mut state.0).unwrap().requests = Arc::new(Semaphore::new(2));
        let app = Router::new()
            .route("/large", get(|| async { Json("x".repeat(64 * 1024)) }))
            .layer(axum::middleware::from_fn_with_state(state.clone(), admit))
            .merge(crate::router(state.clone()));
        let (connections, incoming) = mpsc::channel(4);
        let server = tokio::spawn(async move {
            axum::serve(MemoryListener(incoming), app).await.unwrap();
        });
        let mut first = connect(&connections, "/large", "HTTP/1.1 200").await;
        let second = connect(&connections, "/large", "HTTP/1.1 200").await;
        // Hyper has polled the final frame and dropped the body by now, but
        // cannot write the frame into the bounded, unread transport.
        assert_eq!(state.0.requests.available_permits(), 0);
        let mut rejected = connect(&connections, "/health", "HTTP/1.1 429").await;
        let mut bytes = Vec::new();
        rejected.read_to_end(&mut bytes).await.unwrap();
        let error: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(error["error"], "server capacity reached; retry later");

        // Finishing the write releases one slot while the other stays blocked.
        bytes.clear();
        first.read_to_end(&mut bytes).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<String>(&bytes).unwrap().len(),
            64 * 1024
        );
        assert_eq!(state.0.requests.available_permits(), 1);
        // Disconnect releases the transport-owned final frame too.
        drop(second);
        while state.0.requests.available_permits() != 2 {
            tokio::task::yield_now().await;
        }
        let mut healthy = connect(&connections, "/health", "HTTP/1.1 200").await;
        healthy.read_to_end(&mut Vec::new()).await.unwrap();
        assert_eq!(state.0.body_bytes.available_permits(), 1024);
        server.abort();
        let _ = server.await;
    })
    .await
    .expect("backpressure admission or recovery stalled");
}
