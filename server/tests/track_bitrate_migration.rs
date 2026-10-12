#[tokio::test]
async fn legacy_tracks_keep_null_bitrate_and_new_values_must_be_positive() {
    let pool = sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    let mut legacy_migrations = sqlx::migrate!();
    legacy_migrations.migrations = legacy_migrations
        .iter()
        .filter(|migration| migration.version < 3)
        .cloned()
        .collect::<Vec<_>>()
        .into();
    legacy_migrations.run(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO users(id,username,password_hash,revision) VALUES('user','legacy','hash',7)",
    )
    .execute(&pool)
    .await
    .unwrap();
    const INSERT_TRACK: &str = "INSERT INTO tracks(id,user_id,title,artist,album,album_artist,duration_ms,size_bytes,sha256,mime_type,audio_path,revision,created_at) VALUES(?,'user','title','','','',1000,16044,?,'audio/wav','missing.audio',7,0)";
    sqlx::query(INSERT_TRACK)
        .bind("legacy")
        .bind("legacy-hash")
        .execute(&pool)
        .await
        .unwrap();

    sqlx::migrate!().run(&pool).await.unwrap();
    // Omitting bitrate still defaults to NULL for rows inserted after migration.
    sqlx::query(INSERT_TRACK)
        .bind("new")
        .bind("new-hash")
        .execute(&pool)
        .await
        .unwrap();
    for id in ["legacy", "new"] {
        let row: (Option<i64>, i64) =
            sqlx::query_as("SELECT bitrate_kbps,revision FROM tracks WHERE id=?")
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(row, (None, 7));
    }
    for bitrate in [0, -1] {
        assert!(
            sqlx::query("UPDATE tracks SET bitrate_kbps=? WHERE id='new'")
                .bind(bitrate)
                .execute(&pool)
                .await
                .is_err()
        );
    }
    sqlx::query("UPDATE tracks SET bitrate_kbps=128 WHERE id='new'")
        .execute(&pool)
        .await
        .unwrap();
    let bitrate: Option<i64> = sqlx::query_scalar("SELECT bitrate_kbps FROM tracks WHERE id='new'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(bitrate, Some(128));
    sqlx::query("UPDATE tracks SET bitrate_kbps=NULL WHERE id='new'")
        .execute(&pool)
        .await
        .unwrap();
    pool.close().await;
}
