use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sqlx::{SqlitePool, sqlite::SqliteConnectOptions};
use std::{
    ffi::OsString,
    fs,
    path::Path,
    process::{Command, Output},
};
use tempfile::TempDir;
use tower::ServiceExt;
use yun_server::{AppState, BackfillOptions, BackfillReport, Config};

struct Harness {
    dir: TempDir,
    state: AppState,
    pool: SqlitePool,
}

impl Harness {
    async fn new() -> Self {
        Self::open(tempfile::tempdir().unwrap()).await
    }

    async fn open(dir: TempDir) -> Self {
        let state = AppState::open(Config::new(dir.path())).await.unwrap();
        let pool = SqlitePool::connect_with(
            SqliteConnectOptions::new()
                .filename(dir.path().join("yun.sqlite3"))
                .foreign_keys(true),
        )
        .await
        .unwrap();
        Self { dir, state, pool }
    }

    async fn user(&self, name: &str, revision: i64) -> String {
        let id = yun_server::create_user(&self.state, name, "backfill-test-password")
            .await
            .unwrap();
        sqlx::query("UPDATE users SET revision=? WHERE id=?")
            .bind(revision)
            .bind(&id)
            .execute(&self.pool)
            .await
            .unwrap();
        id
    }

    async fn seed(
        &self,
        id: &str,
        user: &str,
        bytes: Option<&[u8]>,
        bitrate: Option<i64>,
        deleted: bool,
    ) {
        if let Some(bytes) = bytes {
            fs::write(self.dir.path().join("media").join(id), bytes).unwrap();
        }
        fs::write(self.dir.path().join("media/cover.bin"), b"cached artwork").unwrap();
        // Manual metadata deliberately differs from the file's properties/tags.
        sqlx::query(
            "INSERT INTO tracks(id,user_id,title,artist,album,album_artist,track_number,disc_number,
             duration_ms,size_bytes,sha256,mime_type,artwork_mime,artwork_path,artwork_size_bytes,
             audio_path,revision,created_at,deleted,bitrate_kbps)
             VALUES(?,?,'Manual title','Manual artist','Manual album','Manual album artist',3,2,
             4321,?,?,'audio/wav','image/png','cover.bin',14,?,?,1234,?,?)",
        )
        .bind(id)
        .bind(user)
        .bind(bytes.map_or(16044, |bytes| bytes.len() as i64))
        .bind(format!("legacy-sha-{id}"))
        .bind(id)
        .bind(self.revision(user).await)
        .bind(deleted)
        .bind(bitrate)
        .execute(&self.pool)
        .await
        .unwrap();
    }

    async fn revision(&self, user: &str) -> i64 {
        sqlx::query_scalar("SELECT revision FROM users WHERE id=?")
            .bind(user)
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    async fn track(&self, id: &str) -> (Option<i64>, i64) {
        sqlx::query_as("SELECT bitrate_kbps,revision FROM tracks WHERE id=?")
            .bind(id)
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    async fn metadata(&self) -> Vec<String> {
        // All track columns except the two that backfill is allowed to change.
        sqlx::query_scalar(
            "SELECT json_array(id,user_id,title,artist,album,album_artist,track_number,disc_number,
             duration_ms,size_bytes,sha256,mime_type,artwork_mime,artwork_path,artwork_size_bytes,
             audio_path,created_at,deleted) FROM tracks ORDER BY id",
        )
        .fetch_all(&self.pool)
        .await
        .unwrap()
    }

    fn files(&self) -> Vec<(OsString, Vec<u8>)> {
        let mut files: Vec<_> = fs::read_dir(self.dir.path().join("media"))
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                (entry.file_name(), fs::read(entry.path()).unwrap())
            })
            .collect();
        files.sort_by(|a, b| a.0.cmp(&b.0));
        files
    }

    async fn close(self) -> TempDir {
        self.pool.close().await;
        self.state.close().await;
        // close() closes SQLite, but the process lock lives until AppState drops.
        drop(self.state);
        self.dir
    }
}

fn wav(sample_rate: u32) -> Vec<u8> {
    // One second of mono 16-bit PCM: 8 kHz => 128 kbps; 8 Hz rounds to unknown.
    let length = sample_rate * 2;
    let mut bytes = Vec::new();
    bytes.extend(b"RIFF");
    bytes.extend((length + 36).to_le_bytes());
    bytes.extend(b"WAVEfmt ");
    bytes.extend(16u32.to_le_bytes());
    bytes.extend(1u16.to_le_bytes());
    bytes.extend(1u16.to_le_bytes());
    bytes.extend(sample_rate.to_le_bytes());
    bytes.extend((sample_rate * 2).to_le_bytes());
    bytes.extend(2u16.to_le_bytes());
    bytes.extend(16u16.to_le_bytes());
    bytes.extend(b"data");
    bytes.extend(length.to_le_bytes());
    bytes.resize(length as usize + 44, 0);
    bytes
}

async fn request(
    app: &Router,
    token: Option<&str>,
    method: &str,
    path: &str,
    body: Value,
) -> Value {
    let mut request = Request::builder()
        .method(method)
        .uri(path)
        .header("content-type", "application/json");
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = app
        .clone()
        .oneshot(request.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(
        status,
        StatusCode::OK,
        "{}",
        String::from_utf8_lossy(&bytes)
    );
    serde_json::from_slice(&bytes).unwrap()
}

async fn login(app: &Router, username: &str) -> String {
    request(
        app,
        None,
        "POST",
        "/api/v1/auth/login",
        json!({"username":username,"password":"backfill-test-password","device_id":uuid::Uuid::new_v4().to_string()}),
    )
    .await["access_token"]
        .as_str()
        .unwrap()
        .to_owned()
}

#[tokio::test]
async fn mixed_batch_preserves_originals_and_syncs_each_accounts_changes_once() {
    let h = Harness::new().await;
    let alice = h.user("alice", 10).await;
    let bob = h.user("bob", 20).await;
    let audio = wav(8000);
    for (id, user, bytes, bitrate, deleted) in [
        ("01-alice-wav", &alice, Some(audio.as_slice()), None, false),
        ("02-known", &alice, None, Some(96), false),
        ("03-bob-wav", &bob, Some(audio.as_slice()), None, false),
        (
            "04-alice-mp3",
            &alice,
            Some(include_bytes!("fixtures/tone.mp3").as_slice()),
            None,
            false,
        ),
        ("05-deleted", &bob, None, None, true),
        ("06-missing", &alice, None, None, false),
        (
            "07-malformed",
            &bob,
            Some(b"not audio".as_slice()),
            None,
            false,
        ),
        ("08-unknown", &bob, Some(wav(8).as_slice()), None, false),
        (
            "09-after-failures",
            &alice,
            Some(audio.as_slice()),
            None,
            false,
        ),
    ] {
        h.seed(id, user, bytes, bitrate, deleted).await;
    }
    let metadata = h.metadata().await;
    let files = h.files();
    let app = yun_server::router(h.state.clone());
    let tokens = [login(&app, "alice").await, login(&app, "bob").await];
    let mut cursors = Vec::new();
    for token in &tokens {
        let snapshot = request(&app, Some(token), "GET", "/api/v1/library", json!({})).await;
        cursors.push(snapshot["cursor"].as_i64().unwrap());
    }
    assert_eq!(cursors, [10, 20]);

    assert_eq!(
        h.state
            .backfill_bitrates(BackfillOptions::default())
            .await
            .unwrap(),
        BackfillReport {
            scanned: 7,
            updated: 4,
            unavailable: 1,
            failed: 2,
            skipped: 0
        }
    );
    assert_eq!(h.revision(&alice).await, 11);
    assert_eq!(h.revision(&bob).await, 21);
    for (id, revision) in [
        ("01-alice-wav", 11),
        ("03-bob-wav", 21),
        ("09-after-failures", 11),
    ] {
        assert_eq!(h.track(id).await, (Some(128), revision));
    }
    let (compressed_bitrate, revision) = h.track("04-alice-mp3").await;
    assert!(compressed_bitrate.is_some_and(|value| value > 0));
    assert_eq!(revision, 11);
    for (id, bitrate, revision) in [
        ("02-known", Some(96), 10),
        ("05-deleted", None, 20),
        ("06-missing", None, 10),
        ("07-malformed", None, 20),
        ("08-unknown", None, 20),
    ] {
        assert_eq!(h.track(id).await, (bitrate, revision), "{id}");
    }
    assert_eq!(h.metadata().await, metadata);
    assert_eq!(h.files(), files);

    for (index, expected_ids) in [
        vec!["01-alice-wav", "04-alice-mp3", "09-after-failures"],
        vec!["03-bob-wav"],
    ]
    .into_iter()
    .enumerate()
    {
        for paged in [false, true] {
            let delta = request(
                &app,
                Some(&tokens[index]),
                "GET",
                &format!("/api/v1/library?cursor={}&paged={paged}", cursors[index]),
                json!({}),
            )
            .await;
            assert_eq!(delta["cursor"], cursors[index] + 1);
            assert_eq!(delta["reset"], false);
            let tracks = delta["tracks"].as_array().unwrap();
            assert_eq!(
                tracks
                    .iter()
                    .map(|track| track["id"].as_str().unwrap())
                    .collect::<Vec<_>>(),
                expected_ids
            );
            for track in tracks {
                assert!(track["bitrate_kbps"].as_i64().unwrap() > 0);
                assert_eq!(track["revision"], cursors[index] + 1);
                assert_eq!(track["title"], "Manual title");
                assert_eq!(track["has_artwork"], true);
            }
            assert_eq!(delta["deleted_track_ids"], json!([]));
            assert_eq!(delta["playlists"], json!([]));
        }
    }
    // Failed and unavailable NULLs are retried, but never cause revision churn.
    assert_eq!(
        h.state
            .backfill_bitrates(BackfillOptions::default())
            .await
            .unwrap(),
        BackfillReport {
            scanned: 3,
            updated: 0,
            unavailable: 1,
            failed: 2,
            skipped: 0
        }
    );
    for (index, token) in tokens.iter().enumerate() {
        let delta = request(
            &app,
            Some(token),
            "GET",
            &format!("/api/v1/library?cursor={}", cursors[index] + 1),
            json!({}),
        )
        .await;
        assert_eq!(delta["cursor"], cursors[index] + 1);
        assert_eq!(delta["tracks"], json!([]));
    }
    assert_eq!(h.metadata().await, metadata);
    assert_eq!(h.files(), files);
    drop(app);
    h.close().await;
}

#[tokio::test]
async fn single_row_batches_follow_id_order_and_resume_after_missing_file_is_repaired() {
    let h = Harness::new().await;
    let user = h.user("alice", 10).await;
    let audio = wav(8000);
    // Reverse insertion order ensures revisions reveal ORDER BY id, not rowid.
    h.seed("c-last", &user, Some(&audio), None, false).await;
    h.seed("b-missing", &user, None, None, false).await;
    h.seed("a-first", &user, Some(&audio), None, false).await;
    let options = BackfillOptions {
        batch_size: 1,
        concurrency: 1,
    };
    assert_eq!(
        h.state.backfill_bitrates(options).await.unwrap(),
        BackfillReport {
            scanned: 3,
            updated: 2,
            failed: 1,
            ..BackfillReport::default()
        }
    );
    assert_eq!(h.track("a-first").await, (Some(128), 11));
    assert_eq!(h.track("b-missing").await, (None, 10));
    assert_eq!(h.track("c-last").await, (Some(128), 12));
    let dir = h.close().await;
    // Even an absent already-filled original must not be parsed on the rerun.
    fs::remove_file(dir.path().join("media/a-first")).unwrap();
    fs::write(dir.path().join("media/b-missing"), &audio).unwrap();
    let h = Harness::open(dir).await;
    assert_eq!(
        h.state.backfill_bitrates(options).await.unwrap(),
        BackfillReport {
            scanned: 1,
            updated: 1,
            ..BackfillReport::default()
        }
    );
    assert_eq!(h.track("a-first").await, (Some(128), 11));
    assert_eq!(h.track("b-missing").await, (Some(128), 13));
    assert_eq!(h.track("c-last").await, (Some(128), 12));
    assert_eq!(h.revision(&user).await, 13);
    assert_eq!(
        h.state.backfill_bitrates(options).await.unwrap(),
        BackfillReport::default()
    );
    h.close().await;
}

#[tokio::test]
async fn failed_revision_transaction_rolls_back_entire_batch_but_keeps_prior_commits() {
    let h = Harness::new().await;
    let alice = h.user("alice", 10).await;
    let bob = h.user("bob", 20).await;
    for (id, user) in [("a", &alice), ("b", &alice), ("c", &alice), ("d", &bob)] {
        h.seed(id, user, Some(&wav(8000)), None, false).await;
    }
    // Fail the second batch at its account revision bump, after at least one
    // bitrate UPDATE has run. Both accounts' changes must roll back together.
    sqlx::query(
        "CREATE TRIGGER reject_bob_revision BEFORE UPDATE OF revision ON users
        WHEN OLD.username='bob' BEGIN SELECT RAISE(ABORT,'injected revision failure'); END",
    )
    .execute(&h.pool)
    .await
    .unwrap();
    let options = BackfillOptions {
        batch_size: 2,
        concurrency: 2,
    };
    assert!(h.state.backfill_bitrates(options).await.is_err());
    assert_eq!(h.track("a").await, (Some(128), 11));
    assert_eq!(h.track("b").await, (Some(128), 11));
    assert_eq!(h.track("c").await, (None, 10));
    assert_eq!(h.track("d").await, (None, 20));
    assert_eq!(h.revision(&alice).await, 11);
    assert_eq!(h.revision(&bob).await, 20);
    let dir = h.close().await;
    let h = Harness::open(dir).await;
    sqlx::query("DROP TRIGGER reject_bob_revision")
        .execute(&h.pool)
        .await
        .unwrap();
    assert_eq!(
        h.state.backfill_bitrates(options).await.unwrap(),
        BackfillReport {
            scanned: 2,
            updated: 2,
            ..BackfillReport::default()
        }
    );
    assert_eq!(h.track("c").await, (Some(128), 12));
    assert_eq!(h.track("d").await, (Some(128), 21));
    assert_eq!(h.revision(&alice).await, 12);
    assert_eq!(h.revision(&bob).await, 21);
    h.close().await;
}

#[tokio::test]
async fn options_validate_before_mutating_and_accept_upper_bounds() {
    let h = Harness::new().await;
    let defaults = BackfillOptions::default();
    assert_eq!((defaults.batch_size, defaults.concurrency), (32, 2));
    assert_eq!(
        h.state.backfill_bitrates(defaults).await.unwrap(),
        BackfillReport::default()
    );
    let user = h.user("alice", 10).await;
    h.seed("candidate", &user, Some(&wav(8000)), None, false)
        .await;
    for (batch_size, concurrency, message) in [
        (0, 1, "batch size"),
        (129, 1, "batch size"),
        (u16::MAX, 1, "batch size"),
        (1, 0, "concurrency"),
        (1, 3, "concurrency"),
        (1, u8::MAX, "concurrency"),
    ] {
        let error = h
            .state
            .backfill_bitrates(BackfillOptions {
                batch_size,
                concurrency,
            })
            .await
            .unwrap_err();
        assert!(error.to_string().contains(message), "{error}");
        assert_eq!(h.track("candidate").await, (None, 10));
        assert_eq!(h.revision(&user).await, 10);
    }
    assert_eq!(
        h.state
            .backfill_bitrates(BackfillOptions {
                batch_size: 128,
                concurrency: 2
            })
            .await
            .unwrap(),
        BackfillReport {
            scanned: 1,
            updated: 1,
            ..BackfillReport::default()
        }
    );
    h.close().await;
}

#[tokio::test]
async fn failed_commit_rolls_back_bitrate_and_sync_revisions_then_resumes() {
    let h = Harness::new().await;
    let user = h.user("alice", 10).await;
    let audio = wav(8000);
    h.seed("a-good", &user, Some(&audio), None, false).await;
    h.seed("b-fail", &user, Some(&audio), None, false).await;
    sqlx::query(
        "CREATE TRIGGER fail_backfill BEFORE UPDATE OF revision ON tracks
         WHEN NEW.id='b-fail' BEGIN SELECT RAISE(ABORT,'simulate failed commit'); END",
    )
    .execute(&h.pool)
    .await
    .unwrap();
    let options = BackfillOptions {
        batch_size: 1,
        concurrency: 1,
    };
    assert!(h.state.backfill_bitrates(options).await.is_err());
    // The first batch is durable. Both the bitrate and account revision from
    // the failing batch roll back together, so clients cannot miss its retry.
    assert_eq!(h.track("a-good").await, (Some(128), 11));
    assert_eq!(h.track("b-fail").await, (None, 10));
    assert_eq!(h.revision(&user).await, 11);
    sqlx::query("DROP TRIGGER fail_backfill")
        .execute(&h.pool)
        .await
        .unwrap();
    let dir = h.close().await;
    let h = Harness::open(dir).await;
    assert_eq!(
        h.state.backfill_bitrates(options).await.unwrap(),
        BackfillReport {
            scanned: 1,
            updated: 1,
            ..BackfillReport::default()
        }
    );
    assert_eq!(h.track("a-good").await, (Some(128), 11));
    assert_eq!(h.track("b-fail").await, (Some(128), 12));
    assert_eq!(h.revision(&user).await, 12);
    h.close().await;
}

fn cli(dir: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_yun-server"))
        .arg("--data-dir")
        .arg(dir)
        .arg("backfill-bitrates")
        .args(args)
        .env("RUST_LOG", "warn")
        .output()
        .unwrap()
}

fn assert_summary(output: &Output, expected: &str, success: bool) {
    assert_eq!(output.status.success(), success, "{output:?}");
    assert!(
        String::from_utf8_lossy(&output.stdout).contains(expected),
        "{output:?}"
    );
}

#[tokio::test]
async fn cli_refuses_live_state_reports_failures_and_resumes_committed_batches() {
    let h = Harness::new().await;
    let user = h.user("alice", 10).await;
    h.seed("a-good", &user, Some(&wav(8000)), None, false).await;
    h.seed("b-missing", &user, None, None, false).await;
    let locked = cli(h.dir.path(), &[]);
    assert!(!locked.status.success(), "{locked:?}");
    assert!(
        String::from_utf8_lossy(&locked.stderr).contains("data directory already in use"),
        "{locked:?}"
    );
    assert_eq!(h.track("a-good").await, (None, 10));
    assert_eq!(h.revision(&user).await, 10);
    let dir = h.close().await;
    let failed = cli(dir.path(), &["--batch-size", "1", "--concurrency", "1"]);
    assert_summary(
        &failed,
        "2 scanned, 1 updated, 0 unavailable, 1 failed, 0 skipped",
        false,
    );
    let h = Harness::open(dir).await;
    assert_eq!(h.track("a-good").await, (Some(128), 11));
    assert_eq!(h.track("b-missing").await, (None, 10));
    fs::write(h.dir.path().join("media/b-missing"), wav(8000)).unwrap();
    let dir = h.close().await;
    assert_summary(
        &cli(dir.path(), &[]),
        "1 scanned, 1 updated, 0 unavailable, 0 failed, 0 skipped",
        true,
    );
    let h = Harness::open(dir).await;
    assert_eq!(h.track("a-good").await, (Some(128), 11));
    assert_eq!(h.track("b-missing").await, (Some(128), 12));
    assert_eq!(h.revision(&user).await, 12);
    let dir = h.close().await;
    assert_summary(
        &cli(dir.path(), &["--batch-size", "128", "--concurrency", "2"]),
        "0 scanned, 0 updated, 0 unavailable, 0 failed, 0 skipped",
        true,
    );
}

#[test]
fn cli_rejects_out_of_range_options_before_opening_database() {
    let dir = tempfile::tempdir().unwrap();
    for (option, value) in [
        ("--batch-size", "0"),
        ("--batch-size", "129"),
        ("--concurrency", "0"),
        ("--concurrency", "3"),
    ] {
        let output = cli(dir.path(), &[option, value]);
        assert_eq!(output.status.code(), Some(2), "{output:?}");
        assert!(
            String::from_utf8_lossy(&output.stderr).contains(option),
            "{output:?}"
        );
        assert!(!dir.path().join("yun.sqlite3").exists());
    }
}
