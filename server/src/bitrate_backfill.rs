use crate::{AppState, bump, media};
use sqlx::FromRow;
use std::collections::HashMap;
use tokio::task::JoinSet;

/// Bounds metadata held in memory and concurrent blocking audio parsers.
#[derive(Clone, Copy, Debug)]
pub struct BackfillOptions {
    pub batch_size: u16,
    pub concurrency: u8,
}

impl Default for BackfillOptions {
    fn default() -> Self {
        Self {
            batch_size: 32,
            concurrency: 2,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BackfillReport {
    pub scanned: usize,
    pub updated: usize,
    pub unavailable: usize,
    pub failed: usize,
    pub skipped: usize,
}

#[derive(FromRow)]
struct Candidate {
    id: String,
    user_id: String,
    audio_path: String,
}

pub(crate) async fn run(
    state: &AppState,
    options: BackfillOptions,
) -> anyhow::Result<BackfillReport> {
    anyhow::ensure!(
        (1..=128).contains(&options.batch_size),
        "batch size must be between 1 and 128"
    );
    anyhow::ensure!(
        (1..=2).contains(&options.concurrency),
        "concurrency must be between 1 and 2"
    );
    // CLI holds the data-directory process lock. This also excludes any
    // in-process file deletion/replacement while parsers read immutable audio.
    // No SQL transaction is held during file I/O.
    let _guard = state.0.writes.lock().await;
    let mut report = BackfillReport::default();
    let mut after = String::new();
    loop {
        let batch: Vec<Candidate> = sqlx::query_as(
            "SELECT id,user_id,audio_path FROM tracks WHERE id>? AND deleted=0 AND bitrate_kbps IS NULL ORDER BY id LIMIT ?",
        )
        .bind(&after)
        .bind(i64::from(options.batch_size))
        .fetch_all(&state.0.pool)
        .await?;
        let Some(last) = batch.last() else {
            break;
        };
        // Advance past failures/unknown properties too, so each candidate is
        // attempted once per invocation. A rerun retries only still-null rows.
        after = last.id.clone();
        report.scanned += batch.len();
        let mut reads = JoinSet::new();
        let mut measured = Vec::with_capacity(batch.len());
        for candidate in batch {
            let path = state
                .0
                .config
                .data_dir
                .join("media")
                .join(&candidate.audio_path);
            let permit = state.0.parsers.clone().acquire_owned().await?;
            reads.spawn_blocking(move || {
                let _permit = permit;
                let bitrate = media::read_bitrate(&path);
                (candidate, bitrate)
            });
            if reads.len() >= usize::from(options.concurrency) {
                collect(
                    reads.join_next().await.unwrap()?,
                    &mut measured,
                    &mut report,
                );
            }
        }
        while let Some(result) = reads.join_next().await {
            collect(result?, &mut measured, &mut report);
        }
        if !measured.is_empty() {
            let mut tx = state.0.pool.begin().await?;
            let mut revisions = HashMap::new();
            let mut updated = 0;
            for (candidate, bitrate) in measured {
                let changed = sqlx::query(
                    "UPDATE tracks SET bitrate_kbps=? WHERE id=? AND user_id=? AND audio_path=? AND deleted=0 AND bitrate_kbps IS NULL",
                )
                .bind(bitrate)
                .bind(&candidate.id)
                .bind(&candidate.user_id)
                .bind(&candidate.audio_path)
                .execute(&mut *tx)
                .await?
                .rows_affected();
                if changed == 0 {
                    report.skipped += 1;
                    continue;
                }
                // Share one account revision across its changed tracks in
                // this batch. Bitrate and revision updates commit atomically,
                // making all changed rows visible to incremental client sync.
                let revision = match revisions.get(&candidate.user_id) {
                    Some(revision) => *revision,
                    None => {
                        let revision = bump(&mut tx, &candidate.user_id)
                            .await
                            .map_err(|error| anyhow::anyhow!(error.message))?;
                        revisions.insert(candidate.user_id.clone(), revision);
                        revision
                    }
                };
                sqlx::query("UPDATE tracks SET revision=? WHERE id=? AND user_id=?")
                    .bind(revision)
                    .bind(&candidate.id)
                    .bind(&candidate.user_id)
                    .execute(&mut *tx)
                    .await?;
                updated += 1;
            }
            tx.commit().await?;
            report.updated += updated;
        }
        tracing::info!(
            scanned = report.scanned,
            updated = report.updated,
            unavailable = report.unavailable,
            failed = report.failed,
            skipped = report.skipped,
            "bitrate backfill batch complete"
        );
    }
    Ok(report)
}

fn collect(
    (candidate, result): (Candidate, Result<Option<i64>, crate::ApiError>),
    measured: &mut Vec<(Candidate, i64)>,
    report: &mut BackfillReport,
) {
    match result {
        Ok(Some(bitrate)) => measured.push((candidate, bitrate)),
        Ok(None) => {
            report.unavailable += 1;
            tracing::warn!(
                track_id = candidate.id,
                user_id = candidate.user_id,
                "audio parser could not determine bitrate; keeping it unknown"
            );
        }
        Err(error) => {
            report.failed += 1;
            tracing::warn!(
                track_id = candidate.id,
                user_id = candidate.user_id,
                error = error.message,
                "bitrate backfill could not read audio; keeping it unknown"
            );
        }
    }
}
