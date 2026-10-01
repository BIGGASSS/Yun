use crate::{AppState, Config};
use axum::{
    body::{Body, Bytes},
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use sha2::{Digest, Sha256};
use std::time::Duration;
use tower::ServiceExt;

async fn seeded(bytes: &[u8], size: usize) -> (tempfile::TempDir, AppState, String) {
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
        .bind(hex::encode(Sha256::digest("a".repeat(64)))).execute(&state.0.pool).await.unwrap();
    let id = crate::id();
    sqlx::query("INSERT INTO uploads(id,user_id,filename,size_bytes,offset,updated_at) VALUES(?,'u','tone.mp3',?,?,0)")
        .bind(&id).bind(size as i64).bind(bytes.len() as i64).execute(&state.0.pool).await.unwrap();
    tokio::fs::write(dir.path().join("uploads").join(&id), bytes)
        .await
        .unwrap();
    (dir, state, id)
}
fn request(method: &str, path: &str, body: impl Into<Bytes>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {}", "a".repeat(64)))
        .header("upload-offset", "0")
        .body(Body::from(body.into()))
        .unwrap()
}
async fn wait_until(mut ready: impl AsyncFnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !ready().await {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn canceled_append_keeps_upload_exclusion_but_does_not_hold_global_lock_during_io() {
    let (dir, state, id) = seeded(&[], 4).await;
    let app = crate::router(state.clone());
    let path = format!("/api/v1/uploads/{id}");
    let global = state.0.writes.lock().await;
    let first = tokio::spawn(app.clone().oneshot(request(
        "PATCH",
        &path,
        Bytes::from_static(b"1234"),
    )));
    let file = dir.path().join("uploads").join(&id);
    // The actual file write completes even though global commit exclusion is
    // held elsewhere. This would deadlock with the old chunk lock scope.
    wait_until(async || tokio::fs::metadata(&file).await.unwrap().len() == 4).await;
    first.abort();
    let _ = first.await;
    assert_eq!(state.0.requests.available_permits(), 31);
    assert_eq!(state.0.body_bytes.available_permits(), 1024 - 64);
    let lock = state.upload_lock(&id).await;
    assert!(
        lock.try_lock().is_err(),
        "HTTP cancellation released upload exclusion before commit"
    );
    let offset: i64 = sqlx::query_scalar("SELECT offset FROM uploads WHERE id=?")
        .bind(&id)
        .fetch_one(&state.0.pool)
        .await
        .unwrap();
    assert_eq!(offset, 0);
    let retry = tokio::spawn(app.clone().oneshot(request(
        "PATCH",
        &path,
        Bytes::from_static(b"abcd"),
    )));
    let cleanup_state = state.clone();
    let gc = tokio::spawn(async move { cleanup_state.cleanup().await });
    drop(global);
    assert_eq!(retry.await.unwrap().unwrap().status(), StatusCode::CONFLICT);
    gc.await.unwrap().unwrap();
    assert_eq!(tokio::fs::read(file).await.unwrap(), b"1234");
    assert_eq!(state.0.requests.available_permits(), 32);
    assert_eq!(state.0.body_bytes.available_permits(), 1024);
    assert_eq!(
        app.oneshot(request("DELETE", &path, Bytes::new()))
            .await
            .unwrap()
            .status(),
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn canceled_upload_lock_waiters_release_admission_before_the_holder_finishes() {
    let (dir, state, id) = seeded(&[], 4).await;
    let app = crate::router(state.clone());
    let path = format!("/api/v1/uploads/{id}");
    let guard = state.upload_lock(&id).await.lock_owned().await;
    for (method, route, body) in [
        ("POST", format!("{path}/complete"), Bytes::new()),
        ("PATCH", path.clone(), Bytes::from_static(b"1234")),
        ("DELETE", path.clone(), Bytes::new()),
    ] {
        let waiter = tokio::spawn(app.clone().oneshot(request(method, &route, body)));
        // Only the holder and the handler's pending lock acquisition own this
        // mutex. Admission alone would not prove the handler passed auth yet.
        wait_until(async || state.0.upload_locks.lock().await[&id].strong_count() == 2).await;
        assert_eq!(state.0.requests.available_permits(), 31);
        waiter.abort();
        assert!(waiter.await.unwrap_err().is_cancelled());
        // The holder is deliberately still blocked: canceled waiters must not
        // retain request/body capacity until it completes, or mutate afterward.
        assert_eq!(state.0.requests.available_permits(), 32, "{method}");
        assert_eq!(state.0.body_bytes.available_permits(), 1024, "{method}");
        assert_eq!(state.0.parsers.available_permits(), 2);
        assert_eq!(state.0.upload_locks.lock().await[&id].strong_count(), 1);
    }
    assert_eq!(
        app.oneshot(request("GET", "/health", Bytes::new()))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    drop(guard);
    let _guard = state.upload_lock(&id).await.lock_owned().await;
    let offset: i64 = sqlx::query_scalar("SELECT offset FROM uploads WHERE id=?")
        .bind(&id)
        .fetch_one(&state.0.pool)
        .await
        .unwrap();
    assert_eq!(offset, 0);
    assert!(
        tokio::fs::read(dir.path().join("uploads").join(id))
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn completion_parser_admission_precedes_global_lock_and_cancel_waits_for_commit() {
    let bytes = include_bytes!("../tests/fixtures/tone.mp3");
    let (_dir, state, id) = seeded(bytes, bytes.len()).await;
    let app = crate::router(state.clone());
    let path = format!("/api/v1/uploads/{id}");
    let global = state.0.writes.lock().await;
    let parsers = state.0.parsers.clone().acquire_many_owned(2).await.unwrap();
    let busy = tokio::time::timeout(
        Duration::from_secs(2),
        app.clone()
            .oneshot(request("POST", &format!("{path}/complete"), Bytes::new())),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(busy.status(), StatusCode::TOO_MANY_REQUESTS);
    drop(parsers);
    let complete = tokio::spawn(app.clone().oneshot(request(
        "POST",
        &format!("{path}/complete"),
        Bytes::new(),
    )));
    wait_until(async || state.upload_lock(&id).await.try_lock_owned().is_err()).await;
    complete.abort();
    let _ = complete.await;
    let cancel = tokio::spawn(app.clone().oneshot(request("DELETE", &path, Bytes::new())));
    drop(global);
    let canceled = tokio::time::timeout(Duration::from_secs(5), cancel)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(canceled.status(), StatusCode::NO_CONTENT);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM tracks WHERE deleted=0")
        .fetch_one(&state.0.pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "cancel raced the detached completion");
    let response = app
        .oneshot(request("GET", "/api/v1/library", Bytes::new()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let json: serde_json::Value =
        serde_json::from_slice(&response.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(json["tracks"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn invalid_completion_is_parsed_without_global_write_exclusion() {
    let (_dir, state, id) = seeded(b"not audio", 9).await;
    let app = crate::router(state.clone());
    let _global = state.0.writes.lock().await;
    let response = tokio::time::timeout(
        Duration::from_secs(2),
        app.oneshot(request(
            "POST",
            &format!("/api/v1/uploads/{id}/complete"),
            Bytes::new(),
        )),
    )
    .await
    .expect("parser waited for global lock")
    .unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn gc_cancellation_does_not_cancel_inflight_filesystem_coordination() {
    let (dir, state, id) = seeded(&[], 1).await;
    let orphan = dir.path().join("media").join("orphan");
    tokio::fs::write(&orphan, b"orphan").await.unwrap();
    let global = state.0.writes.lock().await;
    let clone = state.clone();
    let cleanup = tokio::spawn(async move { clone.cleanup().await });
    // The sweep takes per-upload exclusion before waiting for publication.
    // Observing that guard makes cancellation timing deterministic.
    wait_until(async || state.upload_lock(&id).await.try_lock_owned().is_err()).await;
    cleanup.abort();
    let _ = cleanup.await;
    drop(global);
    wait_until(async || !tokio::fs::try_exists(&orphan).await.unwrap()).await;
}

#[tokio::test]
async fn rejected_upload_creation_reclaims_staging_without_waiting_for_gc() {
    for quota in [true, false] {
        let (dir, mut state, id) = seeded(&[], 1).await;
        if quota {
            std::sync::Arc::get_mut(&mut state.0)
                .unwrap()
                .config
                .quota_bytes = 1;
        } else {
            for _ in 1..100 {
                sqlx::query("INSERT INTO uploads(id,user_id,filename,size_bytes,updated_at) VALUES(?,'u','tone.mp3',1,0)")
                    .bind(crate::id()).execute(&state.0.pool).await.unwrap();
            }
        }
        let app = crate::router(state.clone());
        for _ in 0..3 {
            let mut req = request(
                "POST",
                "/api/v1/uploads",
                r#"{"filename":"new.mp3","size_bytes":1}"#,
            );
            req.headers_mut()
                .insert("content-type", "application/json".parse().unwrap());
            let response = app.clone().oneshot(req).await.unwrap();
            assert_eq!(
                response.status(),
                if quota {
                    StatusCode::PAYLOAD_TOO_LARGE
                } else {
                    StatusCode::BAD_REQUEST
                }
            );
            let mut files = tokio::fs::read_dir(dir.path().join("uploads"))
                .await
                .unwrap();
            assert_eq!(
                files.next_entry().await.unwrap().unwrap().file_name(),
                id.as_str()
            );
            assert!(
                files.next_entry().await.unwrap().is_none(),
                "rejected creation leaked a file"
            );
        }
    }
}

#[tokio::test]
async fn gc_preserves_unpublished_artwork_and_drop_reclaims_it() {
    let (dir, state, _) = seeded(&[], 1).await;
    let staged = crate::media::stage_art(&state, b"staged artwork")
        .await
        .unwrap();
    state.cleanup().await.unwrap();
    let mut files = tokio::fs::read_dir(dir.path().join("uploads"))
        .await
        .unwrap();
    let path = files.next_entry().await.unwrap().unwrap().path();
    assert_eq!(path.extension().unwrap(), "art");
    assert_eq!(tokio::fs::read(&path).await.unwrap(), b"staged artwork");
    assert!(files.next_entry().await.unwrap().is_none());
    drop(staged);
    wait_until(async || !tokio::fs::try_exists(&path).await.unwrap()).await;
    state.cleanup().await.unwrap();
}

#[tokio::test]
async fn gc_skips_busy_expired_uploads_and_reclaims_them_after_release() {
    let (dir, state, id) = seeded(b"pending", 7).await;
    let guard = state.upload_lock(&id).await.lock_owned().await;
    state.cleanup().await.unwrap();
    assert!(dir.path().join("uploads").join(&id).exists());
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM uploads")
        .fetch_one(&state.0.pool)
        .await
        .unwrap();
    assert_eq!(count, 1);
    drop(guard);
    state.cleanup().await.unwrap();
    assert!(!dir.path().join("uploads").join(&id).exists());
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM uploads")
        .fetch_one(&state.0.pool)
        .await
        .unwrap();
    assert_eq!(count, 0);
}
