use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use std::{
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    task::{Context, Poll},
};
use tempfile::TempDir;
use tokio::io::{AsyncRead, ReadBuf};
use tokio_util::io::ReaderStream;
use tower::ServiceExt;
use yun_server::{AppState, Config};

fn uid() -> String {
    uuid::Uuid::new_v4().to_string()
}
struct Harness {
    dir: TempDir,
    state: AppState,
    app: Router,
    a: Value,
    b: Value,
    device_a: String,
    device_b: String,
}
impl Harness {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::open(Config::new(dir.path())).await.unwrap();
        yun_server::create_user(&state, "alice", "alice-password-long")
            .await
            .unwrap();
        yun_server::create_user(&state, "bob", "bob-password-long")
            .await
            .unwrap();
        let app = yun_server::router(state.clone());
        let device_a = uid();
        let device_b = uid();
        let (code, a) = json_request(
            &app,
            "POST",
            "/api/v1/auth/login",
            None,
            json!({"username":"alice","password":"alice-password-long","device_id":device_a}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{a}");
        let (code, b) = json_request(
            &app,
            "POST",
            "/api/v1/auth/login",
            None,
            json!({"username":"bob","password":"bob-password-long","device_id":device_b}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{b}");
        Self {
            dir,
            state,
            app,
            a,
            b,
            device_a,
            device_b,
        }
    }
    fn a(&self) -> &str {
        self.a["access_token"].as_str().unwrap()
    }
    fn b(&self) -> &str {
        self.b["access_token"].as_str().unwrap()
    }
    async fn upload(&self, token: &str, bytes: &[u8]) -> Value {
        let (code, result) = json_request(
            &self.app,
            "POST",
            "/api/v1/uploads",
            Some(token),
            json!({"filename":"example.wav","size_bytes":bytes.len()}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{result}");
        let path = format!("/api/v1/uploads/{}", result["id"].as_str().unwrap());
        let (code, _, body) = raw(
            &self.app,
            "PATCH",
            &path,
            Some(token),
            &[("upload-offset", "0")],
            bytes.to_vec(),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{}", String::from_utf8_lossy(&body));
        let (code, track) = json_request(
            &self.app,
            "POST",
            &format!("{path}/complete"),
            Some(token),
            json!({}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{track}");
        track
    }
}
async fn raw(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    headers: &[(&str, &str)],
    bytes: Vec<u8>,
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut request = Request::builder().method(method).uri(path);
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(bytes)).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let bytes = response
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes()
        .to_vec();
    (status, headers, bytes)
}
async fn json_request(
    app: &Router,
    method: &str,
    path: &str,
    token: Option<&str>,
    value: Value,
) -> (StatusCode, Value) {
    let (status, _, body) = raw(
        app,
        method,
        path,
        token,
        &[("content-type", "application/json")],
        serde_json::to_vec(&value).unwrap(),
    )
    .await;
    (
        status,
        if body.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&body)
                .unwrap_or_else(|_| panic!("non-JSON response: {}", String::from_utf8_lossy(&body)))
        },
    )
}
#[derive(Default)]
struct BodyProgress {
    bytes_read: AtomicUsize,
    eof: AtomicBool,
}

struct FragmentedReader {
    bytes: Vec<u8>,
    offset: usize,
    chunk_size: usize,
    yield_next: bool,
    progress: Arc<BodyProgress>,
}

impl AsyncRead for FragmentedReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        if buf.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        // Force separate polls for fragments, without timers or scheduler races.
        if self.yield_next {
            self.yield_next = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        if self.offset == self.bytes.len() {
            self.progress.eof.store(true, Ordering::SeqCst);
            return Poll::Ready(Ok(()));
        }
        let count = self
            .chunk_size
            .min(buf.remaining())
            .min(self.bytes.len() - self.offset);
        buf.put_slice(&self.bytes[self.offset..self.offset + count]);
        self.offset += count;
        self.progress.bytes_read.fetch_add(count, Ordering::SeqCst);
        self.yield_next = true;
        Poll::Ready(Ok(()))
    }
}

fn fragmented_body(bytes: Vec<u8>, chunk_size: usize) -> (Body, Arc<BodyProgress>) {
    assert!(chunk_size > 0);
    let progress = Arc::new(BodyProgress::default());
    let reader = FragmentedReader {
        bytes,
        offset: 0,
        chunk_size,
        yield_next: true,
        progress: progress.clone(),
    };
    // Unknown length: the JSON extractor must actually poll the stream, rather
    // than accepting/rejecting it based on Content-Length or a body size hint.
    (
        Body::from_stream(ReaderStream::with_capacity(reader, chunk_size)),
        progress,
    )
}

fn wav(seconds: u32) -> Vec<u8> {
    let length = seconds * 8000 * 2;
    let mut bytes = Vec::with_capacity(length as usize + 44);
    bytes.extend(b"RIFF");
    bytes.extend((length + 36).to_le_bytes());
    bytes.extend(b"WAVEfmt ");
    bytes.extend(16u32.to_le_bytes());
    bytes.extend(1u16.to_le_bytes());
    bytes.extend(1u16.to_le_bytes());
    bytes.extend(8000u32.to_le_bytes());
    bytes.extend(16000u32.to_le_bytes());
    bytes.extend(2u16.to_le_bytes());
    bytes.extend(16u16.to_le_bytes());
    bytes.extend(b"data");
    bytes.extend(length.to_le_bytes());
    bytes.resize(length as usize + 44, 0);
    bytes
}
fn event(device: &str, session: &str, track: &str, start: i64, ms: i64) -> Value {
    json!({"id":uid(),"device_id":device,"session_id":session,"track_id":track,"started_at":start,"ended_at":start+ms,"listened_ms":ms,"timezone_offset_minutes":120})
}

#[tokio::test]
async fn legacy_library_requests_succeed_when_small_and_require_upgrade_when_large() {
    let h = Harness::new().await;
    let (code, playlist) = json_request(
        &h.app,
        "POST",
        "/api/v1/playlists",
        Some(h.a()),
        json!({"name":"small"}),
    )
    .await;
    assert_eq!(code, StatusCode::OK);
    for query in ["", "?paged=false", "?cursor=0", "?cursor=99"] {
        let (code, library) = json_request(
            &h.app,
            "GET",
            &format!("/api/v1/library{query}"),
            Some(h.a()),
            json!({}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{library}");
        assert_eq!(library["cursor"], 1);
        assert_eq!(library["playlists"], json!([playlist.clone()]));
        assert!(library.get("next_page_token").is_none());
    }
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new().filename(h.dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
    let user = h.a["user"]["id"].as_str().unwrap();
    let mut tx = pool.begin().await.unwrap();
    for _ in 0..128 {
        sqlx::query("INSERT INTO playlists(id,user_id,name,revision,updated_at,deleted) VALUES(?,?,'seed',1,0,0)")
            .bind(uid()).bind(user).execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
    for query in ["", "?paged=false", "?cursor=0", "?cursor=99"] {
        let (code, error) = json_request(
            &h.app,
            "GET",
            &format!("/api/v1/library{query}"),
            Some(h.a()),
            json!({}),
        )
        .await;
        assert_eq!(code, StatusCode::BAD_REQUEST, "{error}");
        let message = error["error"].as_str().unwrap();
        assert!(message.contains("client upgrade required"), "{message}");
        assert!(message.contains("paged=true"), "{message}");
        assert!(error.get("cursor").is_none());
        assert!(error.get("playlists").is_none());
    }
    // A small delta remains compatible even when the complete library is large.
    let (code, delta) = json_request(
        &h.app,
        "GET",
        "/api/v1/library?cursor=1",
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{delta}");
    assert_eq!(delta["playlists"], json!([]));
    assert!(delta.get("next_page_token").is_none());
    let (code, first) = json_request(
        &h.app,
        "GET",
        "/api/v1/library?paged=true",
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{first}");
    assert_eq!(first["playlists"].as_array().unwrap().len(), 128);
    let (code, last) = json_request(
        &h.app,
        "GET",
        &format!(
            "/api/v1/library?page_token={}",
            first["next_page_token"].as_str().unwrap()
        ),
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{last}");
    assert_eq!(last["playlists"].as_array().unwrap().len(), 1);
    assert!(last.get("next_page_token").is_none());
    pool.close().await;
}

#[tokio::test]
async fn bounded_library_pages_fragment_large_playlists_and_reject_changed_revisions() {
    use std::collections::{HashMap, HashSet};
    let h = Harness::new().await;
    let track = h.upload(h.a(), &wav(1)).await;
    let tid = track["id"].as_str().unwrap();
    let (_, playlist) = json_request(
        &h.app,
        "POST",
        "/api/v1/playlists",
        Some(h.a()),
        json!({"name":"large"}),
    )
    .await;
    let entries: Vec<Value> = (0..10000)
        .map(|_| json!({"id":uid(),"track_id":tid}))
        .collect();
    let path = format!("/api/v1/playlists/{}", playlist["id"].as_str().unwrap());
    let (code, updated) = json_request(
        &h.app,
        "PUT",
        &path,
        Some(h.a()),
        json!({"revision":playlist["revision"],"name":"large","entries":entries}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{updated}");
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new().filename(h.dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
    let user = h.a["user"]["id"].as_str().unwrap();
    let mut tx = pool.begin().await.unwrap();
    for deleted in [0, 1] {
        for i in 0..140 {
            let id = uid();
            sqlx::query("INSERT INTO tracks(id,user_id,title,artist,album,album_artist,duration_ms,size_bytes,sha256,mime_type,audio_path,revision,created_at,deleted) VALUES(?,?,'seed','','','',1000,1,?,'audio/wav',?,3,0,?)")
                .bind(&id).bind(user).bind(&id).bind(&id).bind(deleted).execute(&mut *tx).await.unwrap();
            if deleted == 1 || i < 2 {
                sqlx::query("INSERT INTO playlists(id,user_id,name,revision,updated_at,deleted) VALUES(?,?,'seed',3,0,?)")
                    .bind(uid()).bind(user).bind(deleted).execute(&mut *tx).await.unwrap();
            }
        }
    }
    tx.commit().await.unwrap();
    for cursor in [None, Some(1)] {
        let mut url = cursor.map_or_else(
            || "/api/v1/library?paged=true".to_string(),
            |c| format!("/api/v1/library?cursor={c}&paged=true"),
        );
        let mut tracks = HashSet::new();
        let mut deleted_tracks = HashSet::new();
        let mut deleted_playlists = HashSet::new();
        let mut lists: HashMap<String, Vec<Value>> = HashMap::new();
        let mut metadata = HashMap::new();
        let mut pages = 0;
        loop {
            let (code, page) = json_request(&h.app, "GET", &url, Some(h.a()), json!({})).await;
            assert_eq!(code, StatusCode::OK, "{page}");
            assert_eq!(page["cursor"], 3);
            assert_eq!(page["reset"], cursor.is_none());
            let mut records = 0;
            for (field, set) in [
                ("tracks", &mut tracks),
                ("deleted_track_ids", &mut deleted_tracks),
                ("deleted_playlist_ids", &mut deleted_playlists),
            ] {
                for value in page[field].as_array().unwrap() {
                    records += 1;
                    let id = if field == "tracks" {
                        value["id"].as_str().unwrap()
                    } else {
                        value.as_str().unwrap()
                    };
                    assert!(set.insert(id.to_string()), "duplicate {field} {id}");
                }
            }
            for list in page["playlists"].as_array().unwrap() {
                let id = list["id"].as_str().unwrap().to_string();
                let fragment = list["entries"].as_array().unwrap();
                records += 1 + fragment.len();
                lists
                    .entry(id.clone())
                    .or_default()
                    .extend(fragment.iter().cloned());
                let mut meta = list.clone();
                meta.as_object_mut().unwrap().remove("entries");
                if let Some(previous) = metadata.insert(id, meta.clone()) {
                    assert_eq!(previous, meta);
                }
            }
            assert!(records <= 256, "unbounded page: {records}");
            pages += 1;
            assert!(pages < 100, "pagination did not terminate");
            if let Some(token) = page["next_page_token"].as_str() {
                url = format!("/api/v1/library?page_token={token}");
            } else {
                break;
            }
        }
        assert!(pages > 50);
        assert_eq!(tracks.len(), if cursor.is_none() { 141 } else { 140 });
        assert_eq!(deleted_tracks.len(), if cursor.is_none() { 0 } else { 140 });
        assert_eq!(
            deleted_playlists.len(),
            if cursor.is_none() { 0 } else { 140 }
        );
        assert_eq!(lists.len(), 3);
        assert_eq!(lists[playlist["id"].as_str().unwrap()], entries);
    }
    let (_, first) = json_request(
        &h.app,
        "GET",
        "/api/v1/library?paged=true",
        Some(h.a()),
        json!({}),
    )
    .await;
    let next = format!(
        "/api/v1/library?page_token={}",
        first["next_page_token"].as_str().unwrap()
    );
    assert_eq!(
        json_request(&h.app, "GET", &next, Some(h.b()), json!({}))
            .await
            .0,
        StatusCode::BAD_REQUEST
    );
    json_request(
        &h.app,
        "POST",
        "/api/v1/playlists",
        Some(h.a()),
        json!({"name":"mutation"}),
    )
    .await;
    assert_eq!(
        json_request(&h.app, "GET", &next, Some(h.a()), json!({}))
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/library?page_token=garbage",
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    pool.close().await;
}

#[tokio::test]
async fn media_stream_capacity_is_shared_and_held_until_body_drop_or_eof() {
    let h = Harness::new().await;
    let track = h.upload(h.a(), &wav(1)).await;
    let path = format!("/api/v1/tracks/{}/audio", track["id"].as_str().unwrap());
    let request = || {
        Request::builder()
            .uri(&path)
            .header("authorization", format!("Bearer {}", h.a()))
            .body(Body::empty())
            .unwrap()
    };
    let mut responses = Vec::new();
    for _ in 0..32 {
        let response = h.app.clone().oneshot(request()).await.unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        responses.push(response);
    }
    // A new router shares limits through AppState, not a per-service semaphore.
    assert_eq!(
        yun_server::router(h.state.clone())
            .oneshot(request())
            .await
            .unwrap()
            .status(),
        StatusCode::TOO_MANY_REQUESTS
    );
    drop(responses.pop());
    let response = h.app.clone().oneshot(request()).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    response.into_body().collect().await.unwrap();
    assert_eq!(
        h.app.clone().oneshot(request()).await.unwrap().status(),
        StatusCode::OK
    );
}

struct PendingReader(Arc<AtomicBool>);
impl AsyncRead for PendingReader {
    fn poll_read(
        self: Pin<&mut Self>,
        _: &mut Context<'_>,
        _: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        self.0.store(true, Ordering::SeqCst);
        Poll::Pending
    }
}
#[tokio::test]
async fn byte_admission_rejects_before_polling_unknown_length_bodies() {
    let h = Harness::new().await;
    let path = format!("/api/v1/tracks/{}/artwork", uid());
    let mut tasks = Vec::new();
    for _ in 0..6 {
        let polled = Arc::new(AtomicBool::new(false));
        let request = Request::builder()
            .method("PUT")
            .uri(&path)
            .header("authorization", format!("Bearer {}", h.a()))
            .body(Body::from_stream(ReaderStream::new(PendingReader(
                polled.clone(),
            ))))
            .unwrap();
        tasks.push(tokio::spawn(h.app.clone().oneshot(request)));
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !polled.load(Ordering::SeqCst) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
    }
    let (body, progress) = fragmented_body(vec![1; 100], 10);
    let response = yun_server::router(h.state.clone())
        .oneshot(
            Request::builder()
                .method("PUT")
                .uri(&path)
                .header("authorization", format!("Bearer {}", h.a()))
                .body(body)
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(progress.bytes_read.load(Ordering::SeqCst), 0);
    for task in tasks {
        task.abort();
        let _ = task.await;
    }
    // Cancellation returns the full reservation, allowing a normal request.
    let (code, _) = json_request(&h.app, "GET", "/api/v1/library", Some(h.a()), json!({})).await;
    assert_eq!(code, StatusCode::OK);
}

#[tokio::test]
async fn late_offline_events_move_threshold_crossing_without_double_counting() {
    let h = Harness::new().await;
    let track = h.upload(h.a(), &wav(60)).await;
    let tid = track["id"].as_str().unwrap();
    let session = uid();
    let later = event(&h.device_a, &session, tid, 40000, 20000);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[later.clone(),later]})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/stats?from=40000",
            Some(h.a()),
            json!({})
        )
        .await
        .1["play_count"],
        0
    );
    let earlier = event(&h.device_a, &session, tid, 0, 20000);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[earlier]})
        )
        .await
        .0,
        StatusCode::OK
    );
    let (_, stats) = json_request(
        &h.app,
        "GET",
        "/api/v1/stats?from=40000",
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(stats["listened_ms"], 20000);
    assert_eq!(stats["play_count"], 1);
    let shifted = event(&h.device_a, &session, tid, 20000, 10000);
    json_request(
        &h.app,
        "POST",
        "/api/v1/listening-events",
        Some(h.a()),
        json!({"events":[shifted]}),
    )
    .await;
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/stats?from=40000",
            Some(h.a()),
            json!({})
        )
        .await
        .1["play_count"],
        0
    );
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/stats?from=20000&to=40000",
            Some(h.a()),
            json!({})
        )
        .await
        .1["play_count"],
        1
    );
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/stats", Some(h.a()), json!({}))
            .await
            .1["play_count"],
        1
    );
    // Duplicate IDs with different payloads in a single batch are atomic too.
    let a = event(&h.device_a, &uid(), tid, 100000, 1000);
    let mut b = a.clone();
    b["listened_ms"] = json!(500);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[a,b]})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let batch: Vec<Value> = (0..500)
        .map(|i| event(&h.device_a, &uid(), tid, 100000 + i * 2000, 1000))
        .collect();
    for _ in 0..2 {
        let (code, ack) = json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":batch}),
        )
        .await;
        assert_eq!(code, StatusCode::OK, "{ack}");
        assert_eq!(ack["acknowledged_ids"].as_array().unwrap().len(), 500);
    }
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/stats", Some(h.a()), json!({}))
            .await
            .1["listened_ms"],
        550000
    );
}

#[tokio::test]
async fn expired_logout_consumes_streamed_json_before_401_and_allows_refresh() {
    let h = Harness::new().await;
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new().filename(h.dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
    // A legitimate access token expires while its refresh credential remains
    // valid. Explicit expiry makes the regression independent of wall time.
    assert_eq!(
        sqlx::query("UPDATE sessions SET access_expires=0 WHERE user_id=?")
            .bind(h.a["user"]["id"].as_str().unwrap())
            .execute(&pool)
            .await
            .unwrap()
            .rows_affected(),
        1
    );
    pool.close().await;

    let input = serde_json::to_vec(&json!({"refresh_token":h.a["refresh_token"]})).unwrap();
    let length = input.len();
    let (body, progress) = fragmented_body(input, 7);
    let response = h
        .app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/v1/auth/logout")
                .header("authorization", format!("Bearer {}", h.a()))
                .header("content-type", "application/json")
                .body(body)
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    // Check before polling/dropping the response body: returning a 401 with an
    // unread request can break the client's connection before refresh begins.
    assert_eq!(
        progress.bytes_read.load(Ordering::SeqCst),
        length,
        "logout returned 401 before consuming the streamed JSON request"
    );
    assert!(
        progress.eof.load(Ordering::SeqCst),
        "logout must read through request EOF before 401"
    );

    let (code, rotated) = json_request(
        &h.app,
        "POST",
        "/api/v1/auth/refresh",
        None,
        json!({"refresh_token":h.a["refresh_token"]}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{rotated}");
    assert_ne!(rotated["refresh_token"], h.a["refresh_token"]);
    assert_ne!(rotated["access_token"], h.a["access_token"]);
    let access = rotated["access_token"].as_str().unwrap();
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", Some(access), json!({}))
            .await
            .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/logout",
            Some(access),
            json!({"refresh_token":rotated["refresh_token"]})
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", Some(access), json!({}))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/refresh",
            None,
            json!({"refresh_token":rotated["refresh_token"]})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
}

#[tokio::test]
async fn invalid_logout_streamed_json_still_enforces_syntax_and_body_limit() {
    let h = Harness::new().await;
    // The global JSON limit is 2 MiB. An unknown-length stream must be bounded
    // while reading, even when authentication has already failed.
    const JSON_LIMIT: usize = 2 * 1024 * 1024;
    const CHUNK: usize = 16 * 1024;
    let malformed = b"{\"refresh_token\":".to_vec();
    let malformed_length = malformed.len();
    let mut oversized = b"{\"refresh_token\":\"".to_vec();
    oversized.resize(yun_server::MAX_CHUNK + 1, b'a');
    oversized.extend_from_slice(b"\"}");
    for (input, expected) in [
        (malformed, StatusCode::BAD_REQUEST),
        (oversized, StatusCode::PAYLOAD_TOO_LARGE),
    ] {
        let (body, progress) = fragmented_body(input, CHUNK);
        let response = h
            .app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/auth/logout")
                    .header("authorization", "Bearer invalid")
                    .header("content-type", "application/json")
                    .body(body)
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), expected);
        let read = progress.bytes_read.load(Ordering::SeqCst);
        if expected == StatusCode::BAD_REQUEST {
            assert_eq!(read, malformed_length);
            assert!(progress.eof.load(Ordering::SeqCst));
        } else {
            assert!(
                read > JSON_LIMIT && read <= JSON_LIMIT + CHUNK,
                "oversized JSON must stop reading at the body limit, read {read} bytes"
            );
            assert!(!progress.eof.load(Ordering::SeqCst));
        }
    }
}

#[tokio::test]
async fn authentication_rotation_revocation_and_hash_storage() {
    let h = Harness::new().await;
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", None, json!({}))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/login",
            None,
            json!({"username":"alice","password":"wrong","device_id":uid()})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    // An account cannot revoke another account's session.
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/logout",
            Some(h.b()),
            json!({"refresh_token":h.a["refresh_token"]})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let body = json!({"refresh_token":h.a["refresh_token"]});
    let (first, second) = tokio::join!(
        json_request(&h.app, "POST", "/api/v1/auth/refresh", None, body.clone()),
        json_request(&h.app, "POST", "/api/v1/auth/refresh", None, body)
    );
    let rotated = if first.0 == StatusCode::OK {
        assert_eq!(second.0, StatusCode::UNAUTHORIZED);
        first.1
    } else {
        assert_eq!(first.0, StatusCode::UNAUTHORIZED);
        assert_eq!(second.0, StatusCode::OK);
        second.1
    };
    assert_ne!(rotated["refresh_token"], h.a["refresh_token"]);
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", Some(h.a()), json!({}))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    let token = rotated["access_token"].as_str().unwrap();
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", Some(token), json!({}))
            .await
            .0,
        StatusCode::OK
    );
    // Verify persistent credentials are hashes, not plaintext opaque tokens/passwords.
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new().filename(h.dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
    let (access, refresh): (String, String) =
        sqlx::query_as("SELECT access_hash,refresh_hash FROM sessions WHERE user_id=?")
            .bind(rotated["user"]["id"].as_str().unwrap())
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_ne!(access, token);
    assert_ne!(refresh, rotated["refresh_token"].as_str().unwrap());
    let hash: String = sqlx::query_scalar("SELECT password_hash FROM users WHERE username='alice'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert!(hash.starts_with("$argon2id$"));
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/logout",
            Some(token),
            json!({"refresh_token":rotated["refresh_token"]})
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/auth/refresh",
            None,
            json!({"refresh_token":rotated["refresh_token"]})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    yun_server::reset_password(&h.state, "bob", "new-bob-password")
        .await
        .unwrap();
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/library", Some(h.b()), json!({}))
            .await
            .0,
        StatusCode::UNAUTHORIZED
    );
    pool.close().await;
}

#[tokio::test]
async fn durable_resumable_upload_dedup_audio_ranges_and_isolation() {
    let h = Harness::new().await;
    let bytes = wav(2);
    let (code, upload) = json_request(
        &h.app,
        "POST",
        "/api/v1/uploads",
        Some(h.a()),
        json!({"filename":"song.wav","size_bytes":bytes.len()}),
    )
    .await;
    assert_eq!(code, StatusCode::OK);
    let id = upload["id"].as_str().unwrap();
    let path = format!("/api/v1/uploads/{id}");
    for (method, suffix) in [("GET", ""), ("DELETE", ""), ("POST", "/complete")] {
        assert_eq!(
            json_request(
                &h.app,
                method,
                &format!("{path}{suffix}"),
                Some(h.b()),
                json!({})
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
    }
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.b()),
            &[("upload-offset", "0")],
            vec![0]
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "1")],
            vec![0]
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            bytes[..100].to_vec()
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            &format!("{path}/complete"),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        json_request(&h.app, "GET", &path, Some(h.a()), json!({}))
            .await
            .1["offset"],
        100
    );
    assert_eq!(
        tokio::fs::read(h.dir.path().join("uploads").join(id))
            .await
            .unwrap(),
        bytes[..100]
    );
    // Simulate durable uncommitted bytes left after a crash. Only SQL's offset counts.
    use tokio::io::AsyncWriteExt;
    let mut file = tokio::fs::OpenOptions::new()
        .append(true)
        .open(h.dir.path().join("uploads").join(id))
        .await
        .unwrap();
    file.write_all(b"uncommitted tail").await.unwrap();
    file.sync_all().await.unwrap();
    drop(file);
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "100")],
            bytes[100..].to_vec()
        )
        .await
        .0,
        StatusCode::OK
    );
    let (code, track) = json_request(
        &h.app,
        "POST",
        &format!("{path}/complete"),
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{track}");
    assert_eq!(track["duration_ms"], 2000);
    let track_id = track["id"].as_str().unwrap();
    let audio = format!("/api/v1/tracks/{track_id}/audio");
    let (code, headers, body) = raw(&h.app, "GET", &audio, Some(h.a()), &[], vec![]).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(body, bytes);
    assert_eq!(headers["accept-ranges"], "bytes");
    let etag = headers["etag"].to_str().unwrap();
    assert_eq!(etag, format!("\"{}\"", track["sha256"].as_str().unwrap()));
    for (value, start, end) in [
        ("bytes=0-9", 0, 9),
        ("bytes=-10", bytes.len() - 10, bytes.len() - 1),
        ("bytes=100-", 100, bytes.len() - 1),
        ("bytes=10-999999", 10, bytes.len() - 1),
    ] {
        let (code, headers, body) = raw(
            &h.app,
            "GET",
            &audio,
            Some(h.a()),
            &[("range", value), ("if-range", etag)],
            vec![],
        )
        .await;
        assert_eq!(code, StatusCode::PARTIAL_CONTENT);
        assert_eq!(body, bytes[start..=end]);
        assert_eq!(headers["content-length"], (end - start + 1).to_string());
    }
    let (code, _, body) = raw(
        &h.app,
        "GET",
        &audio,
        Some(h.a()),
        &[("range", "bytes=1-2"), ("if-range", "\"stale\"")],
        vec![],
    )
    .await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(body, bytes);
    let (code, headers, body) = raw(&h.app, "HEAD", &audio, Some(h.a()), &[], vec![]).await;
    assert_eq!(code, StatusCode::OK);
    assert!(body.is_empty());
    assert_eq!(headers["content-length"], bytes.len().to_string());
    for value in [
        "bytes=999999-",
        "bytes=2-1",
        "bytes=0-1,3-4",
        "bytes=-0",
        "garbage",
    ] {
        let (code, headers, _) = raw(
            &h.app,
            "GET",
            &audio,
            Some(h.a()),
            &[("range", value)],
            vec![],
        )
        .await;
        assert_eq!(code, StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(headers["content-range"], format!("bytes */{}", bytes.len()));
    }
    for method in ["GET", "HEAD"] {
        assert_eq!(
            raw(&h.app, method, &audio, Some(h.b()), &[], vec![])
                .await
                .0,
            StatusCode::NOT_FOUND
        );
    }
    let duplicate = h.upload(h.a(), &bytes).await;
    assert_eq!(duplicate["id"], track["id"]);
    assert_eq!(duplicate["revision"], track["revision"]);
    let other = h.upload(h.b(), &bytes).await;
    assert_ne!(other["id"], track["id"]);
    assert_eq!(other["sha256"], track["sha256"]);
    let library = json_request(&h.app, "GET", "/api/v1/library", Some(h.b()), json!({}))
        .await
        .1;
    assert_eq!(library["tracks"].as_array().unwrap().len(), 1);
    assert_eq!(library["tracks"][0]["id"], other["id"]);
}

#[tokio::test]
async fn playlist_revisions_track_edits_and_library_tombstones() {
    let h = Harness::new().await;
    let track = h.upload(h.a(), &wav(1)).await;
    let tid = track["id"].as_str().unwrap();
    let (_, playlist) = json_request(
        &h.app,
        "POST",
        "/api/v1/playlists",
        Some(h.a()),
        json!({"name":"Favorites"}),
    )
    .await;
    let path = format!("/api/v1/playlists/{}", playlist["id"].as_str().unwrap());
    let entries = json!([{"id":uid(),"track_id":tid},{"id":uid(),"track_id":tid}]);
    let update = json!({"revision":playlist["revision"],"name":"Reordered","entries":entries});
    assert_eq!(
        json_request(&h.app, "PUT", &path, Some(h.b()), update.clone())
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    let (code, current) = json_request(&h.app, "PUT", &path, Some(h.a()), update.clone()).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(current["entries"], entries);
    assert_eq!(
        json_request(&h.app, "PUT", &path, Some(h.a()), update)
            .await
            .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        json_request(
            &h.app,
            "DELETE",
            &format!("{path}?revision={}", playlist["revision"]),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let other = h.upload(h.b(), &wav(2)).await;
    let bad = json!({"revision":current["revision"],"name":"No","entries":[{"id":uid(),"track_id":other["id"]}]});
    assert_eq!(
        json_request(&h.app, "PUT", &path, Some(h.a()), bad).await.0,
        StatusCode::BAD_REQUEST
    );
    let same = uid();
    assert_eq!(json_request(&h.app,"PUT",&path,Some(h.a()),json!({"revision":current["revision"],"name":"No","entries":[{"id":same,"track_id":tid},{"id":same,"track_id":tid}]})).await.0,StatusCode::BAD_REQUEST);
    let track_path = format!("/api/v1/tracks/{tid}");
    assert_eq!(
        json_request(
            &h.app,
            "PATCH",
            &track_path,
            Some(h.b()),
            json!({"revision":track["revision"],"title":"stolen"})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    let (code,edited)=json_request(&h.app,"PATCH",&track_path,Some(h.a()),json!({"revision":track["revision"],"title":"Manual title","artist":"Artist","track_number":3})).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(edited["track_number"], 3);
    assert_eq!(
        json_request(
            &h.app,
            "PATCH",
            &track_path,
            Some(h.a()),
            json!({"revision":track["revision"],"title":"stale"})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let (_, edited) = json_request(
        &h.app,
        "PATCH",
        &track_path,
        Some(h.a()),
        json!({"revision":edited["revision"],"track_number":null}),
    )
    .await;
    assert!(edited["track_number"].is_null());
    assert_eq!(edited["title"], "Manual title");
    let (_, before) = json_request(&h.app, "GET", "/api/v1/library", Some(h.a()), json!({})).await;
    assert_eq!(before["reset"], true);
    let cursor = before["cursor"].as_i64().unwrap();
    let delta = format!("/api/v1/library?cursor={cursor}");
    assert_eq!(
        json_request(&h.app, "GET", &delta, Some(h.a()), json!({}))
            .await
            .1["tracks"],
        json!([])
    );
    assert_eq!(
        json_request(&h.app, "DELETE", &track_path, Some(h.b()), json!({}))
            .await
            .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        json_request(&h.app, "DELETE", &track_path, Some(h.a()), json!({}))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    let (_, after) = json_request(&h.app, "GET", &delta, Some(h.a()), json!({})).await;
    assert_eq!(after["reset"], false);
    assert_eq!(after["deleted_track_ids"], json!([tid]));
    assert_eq!(after["playlists"][0]["entries"], json!([]));
    assert!(after["cursor"].as_i64().unwrap() > cursor);
    let rev = after["playlists"][0]["revision"].as_i64().unwrap();
    assert_eq!(
        json_request(
            &h.app,
            "DELETE",
            &format!("{path}?revision={rev}"),
            Some(h.b()),
            json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        json_request(
            &h.app,
            "DELETE",
            &format!("{path}?revision={rev}"),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    let (_, after) = json_request(&h.app, "GET", &delta, Some(h.a()), json!({})).await;
    assert_eq!(after["deleted_playlist_ids"], json!([playlist["id"]]));
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/library?cursor=999999",
            Some(h.a()),
            json!({})
        )
        .await
        .1["reset"],
        true
    );
}

#[tokio::test]
async fn offline_events_are_atomic_idempotent_personal_and_rebuildable() {
    let h = Harness::new().await;
    let track = h.upload(h.a(), &wav(60)).await;
    let tid = track["id"].as_str().unwrap();
    let session = uid();
    let a = event(&h.device_a, &session, tid, 1000, 10000);
    let b = event(&h.device_a, &session, tid, 11000, 10000);
    let c = event(&h.device_a, &session, tid, 21000, 10000);
    // Out-of-order offline arrival must produce the same aggregation.
    let batch = json!({"events":[c,a,b]});
    let (code, ack) = json_request(
        &h.app,
        "POST",
        "/api/v1/listening-events",
        Some(h.a()),
        batch.clone(),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{ack}");
    assert_eq!(ack["acknowledged_ids"].as_array().unwrap().len(), 3);
    for _ in 0..3 {
        assert_eq!(
            json_request(
                &h.app,
                "POST",
                "/api/v1/listening-events",
                Some(h.a()),
                batch.clone()
            )
            .await
            .0,
            StatusCode::OK
        );
    }
    let (_, stats) = json_request(&h.app, "GET", "/api/v1/stats", Some(h.a()), json!({})).await;
    assert_eq!(stats["listened_ms"], 30000);
    assert_eq!(stats["play_count"], 1);
    assert_eq!(stats["history"][0]["counted_play"], true);
    let (_, stats) = json_request(
        &h.app,
        "GET",
        "/api/v1/stats?from=11000&to=21000",
        Some(h.a()),
        json!({}),
    )
    .await;
    assert_eq!(stats["listened_ms"], 10000);
    assert_eq!(stats["play_count"], 0);
    assert_eq!(
        json_request(
            &h.app,
            "GET",
            "/api/v1/stats?from=21000&to=31000",
            Some(h.a()),
            json!({})
        )
        .await
        .1["play_count"],
        1
    );
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/stats", Some(h.b()), json!({}))
            .await
            .1["listened_ms"],
        0
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.b()),
            batch
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let valid = event(&h.device_a, &session, tid, 31000, 10000);
    let mut invalid = event(&h.device_a, &session, tid, 41000, 10000);
    invalid["track_id"] = json!(uid());
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[valid,invalid]})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        json_request(&h.app, "GET", "/api/v1/stats", Some(h.a()), json!({}))
            .await
            .1["listened_ms"],
        30000
    );
    let mut altered = a.clone();
    altered["listened_ms"] = json!(9999);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[altered]})
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    let foreign_device = event(&h.device_b, &session, tid, 31000, 10000);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[foreign_device]})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let invalid = event(&h.device_a, &session, tid, 31000, 60001);
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[invalid]})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":vec![a;501]})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        json_request(
            &h.app,
            "DELETE",
            &format!("/api/v1/tracks/{tid}"),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::NO_CONTENT
    );
    h.state.cleanup().await.unwrap();
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/listening-events",
            Some(h.a()),
            json!({"events":[valid]})
        )
        .await
        .0,
        StatusCode::OK
    );
    let (_, stats) = json_request(&h.app, "GET", "/api/v1/stats", Some(h.a()), json!({})).await;
    assert_eq!(stats["listened_ms"], 40000);
    assert_eq!(stats["play_count"], 1);
    assert_eq!(stats["top_tracks"][0]["id"], tid);
}

#[tokio::test]
async fn tags_artwork_and_malformed_payload_limits() {
    use lofty::{
        config::WriteOptions,
        picture::{MimeType, Picture, PictureType},
        prelude::{Accessor, TagExt},
        tag::{Tag, TagType},
    };
    let h = Harness::new().await;
    let mut image = std::io::Cursor::new(Vec::new());
    image::DynamicImage::new_rgb8(2, 2)
        .write_to(&mut image, image::ImageFormat::Png)
        .unwrap();
    let png = image.into_inner();
    let file = h.dir.path().join("tagged.wav");
    tokio::fs::write(&file, wav(1)).await.unwrap();
    let mut tag = Tag::new(TagType::Id3v2);
    tag.set_title("Embedded title".into());
    tag.set_artist("Embedded artist".into());
    tag.set_album("Embedded album".into());
    tag.set_track(7);
    tag.push_picture(Picture::new_unchecked(
        PictureType::CoverFront,
        Some(MimeType::Png),
        None,
        png.clone(),
    ));
    tag.save_to_path(&file, WriteOptions::default()).unwrap();
    let track = h.upload(h.a(), &tokio::fs::read(file).await.unwrap()).await;
    assert_eq!(track["title"], "Embedded title");
    assert_eq!(track["artist"], "Embedded artist");
    assert_eq!(track["track_number"], 7);
    assert_eq!(track["has_artwork"], true);
    let path = format!("/api/v1/tracks/{}/artwork", track["id"].as_str().unwrap());
    let (code, headers, body) = raw(&h.app, "GET", &path, Some(h.a()), &[], vec![]).await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(headers["content-type"], "image/png");
    assert_eq!(body, png);
    assert_eq!(
        raw(&h.app, "GET", &path, Some(h.b()), &[], vec![]).await.0,
        StatusCode::NOT_FOUND
    );
    let revision = format!("\"{}\"", track["revision"]);
    assert_eq!(
        raw(
            &h.app,
            "PUT",
            &path,
            Some(h.b()),
            &[("if-match", &revision)],
            png.clone()
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        raw(&h.app, "PUT", &path, Some(h.a()), &[], png.clone())
            .await
            .0,
        StatusCode::PRECONDITION_REQUIRED
    );
    assert_eq!(
        raw(
            &h.app,
            "PUT",
            &path,
            Some(h.a()),
            &[("if-match", &revision)],
            b"not an image".to_vec()
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        raw(
            &h.app,
            "PUT",
            &path,
            Some(h.a()),
            &[("if-match", &revision)],
            png.clone()
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        raw(
            &h.app,
            "PUT",
            &path,
            Some(h.a()),
            &[("if-match", &revision)],
            png
        )
        .await
        .0,
        StatusCode::CONFLICT
    );
    assert_eq!(
        raw(
            &h.app,
            "PUT",
            &path,
            Some(h.a()),
            &[("if-match", &revision)],
            vec![0; yun_server::MAX_ARTWORK + 1]
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let (_, upload) = json_request(
        &h.app,
        "POST",
        "/api/v1/uploads",
        Some(h.a()),
        json!({"filename":"malicious.mp3","size_bytes":20}),
    )
    .await;
    let path = format!("/api/v1/uploads/{}", upload["id"].as_str().unwrap());
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            vec![0; yun_server::MAX_CHUNK + 1]
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            vec![0; 21]
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            vec![0; 20]
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            &format!("{path}/complete"),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    assert_eq!(
        json_request(&h.app, "DELETE", &path, Some(h.a()), json!({}))
            .await
            .0,
        StatusCode::NO_CONTENT
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            "/api/v1/uploads",
            Some(h.a()),
            json!({"filename":"../escape","size_bytes":1})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
    let (code, _, body) = raw(
        &h.app,
        "POST",
        "/api/v1/uploads",
        Some(h.a()),
        &[("content-type", "application/json")],
        b"{".to_vec(),
    )
    .await;
    assert_eq!(code, StatusCode::BAD_REQUEST);
    assert!(serde_json::from_slice::<Value>(&body).unwrap()["error"].is_string());
}

#[tokio::test]
async fn restart_resume_backup_cleanup_and_quota_reservations() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = Config::new(dir.path().join("data"));
    config.quota_bytes = 40000;
    config.max_file_bytes = 30000;
    config.upload_ttl_ms = 1000;
    let state = AppState::open(config.clone()).await.unwrap();
    assert!(AppState::open(config.clone()).await.is_err());
    yun_server::create_user(&state, "alice", "alice-password-long")
        .await
        .unwrap();
    let app = yun_server::router(state.clone());
    let (_, login) = json_request(
        &app,
        "POST",
        "/api/v1/auth/login",
        None,
        json!({"username":"alice","password":"alice-password-long","device_id":uid()}),
    )
    .await;
    let token = login["access_token"].as_str().unwrap();
    assert_eq!(
        json_request(
            &app,
            "POST",
            "/api/v1/uploads",
            Some(token),
            json!({"filename":"too-big.wav","size_bytes":30001})
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let bytes = wav(1);
    let (_, upload) = json_request(
        &app,
        "POST",
        "/api/v1/uploads",
        Some(token),
        json!({"filename":"restart.wav","size_bytes":bytes.len()}),
    )
    .await;
    let path = format!("/api/v1/uploads/{}", upload["id"].as_str().unwrap());
    assert_eq!(
        raw(
            &app,
            "PATCH",
            &path,
            Some(token),
            &[("upload-offset", "0")],
            bytes[..100].to_vec()
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &app,
            "POST",
            "/api/v1/uploads",
            Some(token),
            json!({"filename":"reserved.wav","size_bytes":30000})
        )
        .await
        .0,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    drop(app);
    state.close().await;
    drop(state);
    let state = AppState::open(config.clone()).await.unwrap();
    let app = yun_server::router(state.clone());
    assert_eq!(
        json_request(&app, "GET", &path, Some(token), json!({}))
            .await
            .1["offset"],
        100
    );
    assert_eq!(
        raw(
            &app,
            "PATCH",
            &path,
            Some(token),
            &[("upload-offset", "100")],
            bytes[100..].to_vec()
        )
        .await
        .0,
        StatusCode::OK
    );
    let (code, track) = json_request(
        &app,
        "POST",
        &format!("{path}/complete"),
        Some(token),
        json!({}),
    )
    .await;
    assert_eq!(code, StatusCode::OK, "{track}");
    let backup = dir.path().join("backup");
    state.backup(&backup).await.unwrap();
    assert!(state.backup(&backup).await.is_err());
    let restored = AppState::open(Config::new(&backup)).await.unwrap();
    let restored_app = yun_server::router(restored.clone());
    let audio = format!("/api/v1/tracks/{}/audio", track["id"].as_str().unwrap());
    assert_eq!(
        raw(&restored_app, "GET", &audio, Some(token), &[], vec![])
            .await
            .2,
        bytes
    );
    let (_, abandoned) = json_request(
        &app,
        "POST",
        "/api/v1/uploads",
        Some(token),
        json!({"filename":"abandoned.wav","size_bytes":100}),
    )
    .await;
    tokio::fs::write(config.data_dir.join("media").join("orphan"), b"orphan")
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    state.cleanup().await.unwrap();
    assert!(!config.data_dir.join("media").join("orphan").exists());
    assert_eq!(
        json_request(
            &app,
            "GET",
            &format!("/api/v1/uploads/{}", abandoned["id"].as_str().unwrap()),
            Some(token),
            json!({})
        )
        .await
        .0,
        StatusCode::NOT_FOUND
    );
    assert_eq!(
        raw(&app, "GET", &audio, Some(token), &[], vec![]).await.2,
        bytes
    );
}

#[tokio::test]
async fn supported_formats_are_sniffed_not_trusted_from_filename() {
    let h = Harness::new().await;
    let fixtures: &[(&[u8], &str)] = &[
        (include_bytes!("fixtures/tone.mp3"), "audio/mpeg"),
        (include_bytes!("fixtures/tone.flac"), "audio/flac"),
        (include_bytes!("fixtures/tone.m4a"), "audio/mp4"),
        (include_bytes!("fixtures/tone.ogg"), "audio/ogg"),
        (include_bytes!("fixtures/tone.opus"), "audio/ogg"),
        (include_bytes!("fixtures/tone.aac"), "audio/aac"),
        (include_bytes!("fixtures/tone.aiff"), "audio/aiff"),
    ];
    for (bytes, mime) in fixtures {
        let track = h.upload(h.a(), bytes).await; // Deliberately always named example.wav.
        assert_eq!(track["mime_type"], *mime);
        assert!(track["duration_ms"].as_i64().unwrap() >= 200);
        assert!(track["duration_ms"].as_i64().unwrap() < 500);
        if *mime != "audio/aac" && *mime != "audio/aiff" {
            assert_eq!(track["title"], "Fixture title");
            assert_eq!(track["artist"], "Fixture artist");
        }
    }
    let mut truncated = wav(1);
    truncated.truncate(50);
    let (_, upload) = json_request(
        &h.app,
        "POST",
        "/api/v1/uploads",
        Some(h.a()),
        json!({"filename":"truncated.wav","size_bytes":truncated.len()}),
    )
    .await;
    let path = format!("/api/v1/uploads/{}", upload["id"].as_str().unwrap());
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            truncated
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        json_request(
            &h.app,
            "POST",
            &format!("{path}/complete"),
            Some(h.a()),
            json!({})
        )
        .await
        .0,
        StatusCode::BAD_REQUEST
    );
}

#[tokio::test]
async fn concurrent_chunks_and_playlist_writes_have_one_winner_and_completion_retries() {
    let h = Harness::new().await;
    let bytes = wav(1);
    let (_, upload) = json_request(
        &h.app,
        "POST",
        "/api/v1/uploads",
        Some(h.a()),
        json!({"filename":"race.wav","size_bytes":bytes.len()}),
    )
    .await;
    let path = format!("/api/v1/uploads/{}", upload["id"].as_str().unwrap());
    let (a, b) = tokio::join!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            bytes[..100].to_vec()
        ),
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "0")],
            bytes[..100].to_vec()
        )
    );
    assert!(
        (a.0 == StatusCode::OK && b.0 == StatusCode::CONFLICT)
            || (b.0 == StatusCode::OK && a.0 == StatusCode::CONFLICT)
    );
    assert_eq!(
        raw(
            &h.app,
            "PATCH",
            &path,
            Some(h.a()),
            &[("upload-offset", "100")],
            bytes[100..].to_vec()
        )
        .await
        .0,
        StatusCode::OK
    );
    let complete = format!("{path}/complete");
    let (a, b) = tokio::join!(
        json_request(&h.app, "POST", &complete, Some(h.a()), json!({})),
        json_request(&h.app, "POST", &complete, Some(h.a()), json!({}))
    );
    assert_eq!(a.0, StatusCode::OK);
    assert_eq!(b.0, StatusCode::OK);
    assert_eq!(a.1, b.1);
    assert_eq!(
        json_request(&h.app, "GET", &path, Some(h.a()), json!({}))
            .await
            .1["offset"],
        bytes.len()
    );
    let (_, playlist) = json_request(
        &h.app,
        "POST",
        "/api/v1/playlists",
        Some(h.a()),
        json!({"name":"race"}),
    )
    .await;
    let path = format!("/api/v1/playlists/{}", playlist["id"].as_str().unwrap());
    let input = json!({"revision":playlist["revision"],"name":"winner","entries":[]});
    let (a, b) = tokio::join!(
        json_request(&h.app, "PUT", &path, Some(h.a()), input.clone()),
        json_request(&h.app, "PUT", &path, Some(h.a()), input)
    );
    assert!(
        (a.0 == StatusCode::OK && b.0 == StatusCode::CONFLICT)
            || (b.0 == StatusCode::OK && a.0 == StatusCode::CONFLICT)
    );
}

#[tokio::test]
async fn expiry_and_authentication_rate_limits() {
    let dir = tempfile::tempdir().unwrap();
    let state = AppState::open(Config::new(dir.path())).await.unwrap();
    yun_server::create_user(&state, "alice", "alice-password-long")
        .await
        .unwrap();
    let app = yun_server::router(state.clone());
    let (_, login) = json_request(
        &app,
        "POST",
        "/api/v1/auth/login",
        None,
        json!({"username":"alice","password":"alice-password-long","device_id":uid()}),
    )
    .await;
    assert_eq!(
        json_request(
            &app,
            "GET",
            "/api/v1/library",
            login["access_token"].as_str(),
            json!({})
        )
        .await
        .0,
        StatusCode::OK
    );
    // Expire the sole session explicitly: millisecond TTLs and sleeps race with
    // database I/O and scheduling on loaded CI runners.
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new().filename(dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
    assert_eq!(
        sqlx::query("UPDATE sessions SET access_expires=0")
            .execute(&pool)
            .await
            .unwrap()
            .rows_affected(),
        1
    );
    assert_eq!(
        json_request(
            &app,
            "GET",
            "/api/v1/library",
            login["access_token"].as_str(),
            json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    let (code, rotated) = json_request(
        &app,
        "POST",
        "/api/v1/auth/refresh",
        None,
        json!({"refresh_token":login["refresh_token"]}),
    )
    .await;
    assert_eq!(code, StatusCode::OK);
    assert_eq!(
        json_request(
            &app,
            "GET",
            "/api/v1/library",
            rotated["access_token"].as_str(),
            json!({})
        )
        .await
        .0,
        StatusCode::OK
    );
    assert_eq!(
        sqlx::query("UPDATE sessions SET refresh_expires=0")
            .execute(&pool)
            .await
            .unwrap()
            .rows_affected(),
        1
    );
    assert_eq!(
        json_request(
            &app,
            "GET",
            "/api/v1/library",
            rotated["access_token"].as_str(),
            json!({})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    pool.close().await;
    assert_eq!(
        json_request(
            &app,
            "POST",
            "/api/v1/auth/refresh",
            None,
            json!({"refresh_token":rotated["refresh_token"]})
        )
        .await
        .0,
        StatusCode::UNAUTHORIZED
    );
    for _ in 0..9 {
        assert_eq!(
            json_request(
                &app,
                "POST",
                "/api/v1/auth/login",
                None,
                json!({"username":"ALICE","password":"wrong","device_id":uid()})
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
    }
    assert_eq!(
        json_request(
            &app,
            "POST",
            "/api/v1/auth/login",
            None,
            json!({"username":"Alice","password":"wrong","device_id":uid()})
        )
        .await
        .0,
        StatusCode::TOO_MANY_REQUESTS
    );
}
