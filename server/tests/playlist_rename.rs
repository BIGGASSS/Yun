use axum::{
    Router,
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sqlx::{SqlitePool, sqlite::SqliteConnectOptions};
use tempfile::TempDir;
use tower::ServiceExt;
use yun_server::{AppState, Config};

fn uid() -> String {
    uuid::Uuid::new_v4().to_string()
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

struct Harness {
    _dir: TempDir,
    state: AppState,
    pool: SqlitePool,
    app: Router,
    token: String,
    user: String,
    tracks: [String; 2],
}

impl Harness {
    async fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let state = AppState::open(Config::new(dir.path())).await.unwrap();
        yun_server::create_user(&state, "alice", "alice-password-long")
            .await
            .unwrap();
        let app = yun_server::router(state.clone());
        let login = request(
            &app,
            None,
            "POST",
            "/api/v1/auth/login",
            json!({"username":"alice","password":"alice-password-long","device_id":uid()}),
        )
        .await;
        let pool = SqlitePool::connect_with(
            SqliteConnectOptions::new().filename(dir.path().join("yun.sqlite3")),
        )
        .await
        .unwrap();
        let user = login["user"]["id"].as_str().unwrap().to_owned();
        let tracks = [uid(), uid()];
        for id in &tracks {
            sqlx::query("INSERT INTO tracks(id,user_id,title,artist,album,album_artist,duration_ms,size_bytes,sha256,mime_type,audio_path,revision,created_at) VALUES(?,?,'seed','','','',1000,1,?,'audio/wav',?,0,0)")
                .bind(id).bind(&user).bind(id).bind(id).execute(&pool).await.unwrap();
        }
        // Persistent triggers observe mutations made through any server pool connection.
        sqlx::query("CREATE TABLE entry_mutations (operation TEXT NOT NULL)")
            .execute(&pool)
            .await
            .unwrap();
        for operation in ["INSERT", "UPDATE", "DELETE"] {
            sqlx::query(&format!(
                "CREATE TRIGGER count_entry_{operation} AFTER {operation} ON playlist_entries BEGIN INSERT INTO entry_mutations VALUES ('{operation}'); END"
            ))
            .execute(&pool)
            .await
            .unwrap();
        }
        Self {
            _dir: dir,
            state,
            pool,
            app,
            token: login["access_token"].as_str().unwrap().to_owned(),
            user,
            tracks,
        }
    }

    async fn create(&self) -> Value {
        request(
            &self.app,
            Some(&self.token),
            "POST",
            "/api/v1/playlists",
            json!({"name":"Original"}),
        )
        .await
    }

    async fn replace(&self, playlist: &Value, name: &str, entries: &[Value]) -> Value {
        request(
            &self.app,
            Some(&self.token),
            "PUT",
            &format!("/api/v1/playlists/{}", playlist["id"].as_str().unwrap()),
            json!({"revision":playlist["revision"],"name":name,"entries":entries}),
        )
        .await
    }

    async fn clear_mutations(&self) {
        sqlx::query("DELETE FROM entry_mutations")
            .execute(&self.pool)
            .await
            .unwrap();
    }

    async fn mutations(&self) -> i64 {
        sqlx::query_scalar("SELECT COUNT(*) FROM entry_mutations")
            .fetch_one(&self.pool)
            .await
            .unwrap()
    }

    async fn close(&self) {
        self.pool.close().await;
        self.state.close().await;
    }
}

#[tokio::test]
async fn large_playlist_rename_does_not_mutate_entries() {
    let h = Harness::new().await;
    // Repeated track IDs are legal; entry IDs and their order must still be compared.
    let entries: Vec<_> = (0..10_000)
        .map(|_| json!({"id":uid(),"track_id":h.tracks[0]}))
        .collect();
    let playlist = h.create().await;
    let playlist = h.replace(&playlist, "Original", &entries).await;
    assert_eq!(h.mutations().await, 10_000);
    h.clear_mutations().await;
    // Make timestamp advancement deterministic without depending on clock resolution.
    sqlx::query("UPDATE playlists SET updated_at=0 WHERE id=?")
        .bind(playlist["id"].as_str().unwrap())
        .execute(&h.pool)
        .await
        .unwrap();

    let renamed = h.replace(&playlist, "Renamed", &entries).await;
    assert_eq!(h.mutations().await, 0, "rename rewrote playlist entries");
    assert_eq!(renamed["entries"], json!(entries));
    assert_eq!(renamed["name"], "Renamed");
    assert_eq!(renamed["id"], playlist["id"]);
    assert_eq!(
        renamed["revision"].as_i64().unwrap(),
        playlist["revision"].as_i64().unwrap() + 1
    );
    assert!(renamed["updated_at"].as_i64().unwrap() > 0);
    let revision: i64 = sqlx::query_scalar("SELECT revision FROM users WHERE id=?")
        .bind(&h.user)
        .fetch_one(&h.pool)
        .await
        .unwrap();
    assert_eq!(renamed["revision"], revision);
    // An identical replacement retains the existing revision-bump semantics, also without churn.
    let unchanged = h.replace(&renamed, "Renamed", &entries).await;
    assert_eq!(h.mutations().await, 0);
    assert_eq!(unchanged["entries"], json!(entries));
    assert_eq!(unchanged["revision"], revision + 1);
    h.close().await;
}

#[tokio::test]
async fn playlist_replacement_detects_entry_identity_track_order_and_length_changes() {
    let h = Harness::new().await;
    let mut playlist = h.create().await;
    let mut entries = vec![
        json!({"id":uid(),"track_id":h.tracks[0]}),
        json!({"id":uid(),"track_id":h.tracks[0]}),
    ];
    playlist = h.replace(&playlist, "Original", &entries).await;
    // Track deletion can leave gaps in positions; only the logical order matters.
    sqlx::query("UPDATE playlist_entries SET position=position+10 WHERE playlist_id=?")
        .bind(playlist["id"].as_str().unwrap())
        .execute(&h.pool)
        .await
        .unwrap();
    h.clear_mutations().await;
    playlist = h.replace(&playlist, "Gapped renamed", &entries).await;
    assert_eq!(h.mutations().await, 0);
    assert_eq!(playlist["entries"], json!(entries));

    for change in [
        "entry ID", "track ID", "order", "removal", "addition", "clear",
    ] {
        match change {
            "entry ID" => entries[0]["id"] = json!(uid()),
            "track ID" => entries[0]["track_id"] = json!(h.tracks[1]),
            "order" => entries.swap(0, 1),
            "removal" => {
                entries.pop();
            }
            "addition" => entries.push(json!({"id":uid(),"track_id":h.tracks[0]})),
            "clear" => entries.clear(),
            _ => unreachable!(),
        }
        h.clear_mutations().await;
        let updated = h.replace(&playlist, "Original", &entries).await;
        assert!(h.mutations().await > 0, "missed {change} change");
        assert_eq!(updated["entries"], json!(entries), "{change}");
        assert_eq!(
            updated["revision"].as_i64().unwrap(),
            playlist["revision"].as_i64().unwrap() + 1
        );
        playlist = updated;
    }
    h.clear_mutations().await;
    let renamed = h.replace(&playlist, "Empty renamed", &entries).await;
    assert_eq!(h.mutations().await, 0);
    assert_eq!(renamed["entries"], json!([]));
    h.close().await;
}
