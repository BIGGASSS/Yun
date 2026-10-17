# Offline and privacy

## Downloads

Download tracks, albums, or playlists explicitly. When connected, playlist selections follow server changes. Overlapping selections share one copy. Selected downloads are not evicted to make room.

“Keep offline” is not a separate permanent archive. After sync confirms a server-side track deletion, its direct track selection is removed and unreferenced downloaded audio is reclaimed. Album and playlist selections remain. A disconnected client keeps its last known library until it can sync; an empty or failed request is not proof of deletion. Listening history and pending events survive cleanup.

Artwork has a separate, bounded 1 GiB cache per account. Artwork currently on screen is protected from speculative eviction. If artwork doesn't fit, placeholders are shown instead of repeatedly downloading and evicting it. A new foreground request or artwork revision can retry after a capacity miss.

Selected uploads are first copied into account-private staging storage (up to 1 GiB per file by default). Successful or cancelled jobs delete only these staged copies, never your originals. Budget staging space on top of downloads. Transfers run while the app is running and resume later; the app doesn't promise OS-scheduled transfers after it exits.

## Data directory

In **Settings → Data storage**, view the current directory and choose a different folder. **Use default location** restores the platform's application-support location. You can cancel a pending change before restarting. Fully quit Yun (not just minimize to the tray) and reopen it to apply the change.

Choose an existing, writable folder without `accounts` or `artwork` entries. Unrelated files are left alone. Nested source/destination folders and symlinked destinations are rejected. On Android, only folders accessible to the app as ordinary filesystem paths are supported; protected folders and document-provider-only locations cannot be used. On macOS, the folder picker retains sandbox permission across launches.

At the next launch, before opening any account database, Yun copies all accounts' downloads, partial downloads, upload staging, cached libraries, artwork, offline selections, and pending listening history. It updates managed paths in the copied databases, then switches directories only after a successful copy and saved configuration. Original upload source files, server data, system preferences, and secure credentials do not move. The atomic location/recovery configuration (`.yun-data-config.json`) stays in system application support. Old managed copies are removed only after the switch; changed files or external upload originals are retained. Such retained entries may need to be moved aside before reusing an old directory.

Keep both locations connected, leave enough destination space for the full copy, and close other Yun instances before restarting. Do not remove the reserved `.yun-data-*` identity/recovery files. If copying fails, Yun keeps the original location and shows the error in Settings; cancel or choose another destination. An interrupted copy is recovered on startup. If the active drive is missing or its identity has changed, startup stops instead of silently opening an empty library: reconnect the original drive and choose **Retry**. Do not manually move the files while Yun is running. Concurrent app instances and power-loss durability across filesystem/preferences writes are not guaranteed.

## Purge unused downloads

In **Downloads**, choose **Purge unused downloads** to preview the file count and space recoverable from unselected audio and interrupted partial files. Confirm **Purge** to remove them, or cancel to leave them unchanged. **Clear All** in Activity only dismisses completed entries; it does not remove audio.

Purge works offline using the last synced library and never contacts the server or starts downloads. Selected downloads, the current track (even when paused), artwork, uploads, source originals, and pending listening history are protected. Wait for active downloads or verification to finish before purging.

Confirmation rechecks selections and file identity. Newly selected, replaced, or newly created files are not deleted, so the actual freed space may be smaller than the preview. Previews cannot be reused after signing out or switching accounts. Purge does not remove music from your server library.

## Playback and sign-out

Signed-in accounts can browse and play cached music with expired tokens or no network. Completed downloads always play from the device, including on repeated Play attempts and after failed or interrupted repairs. A missing, unreadable, or undecodable local copy shows a playback error instead of streaming silently.

When connected, choose **Redownload** in the player or beside a failed download to replace the file. Playback does not restart automatically. Decoder errors alone never delete downloaded bytes. Tracks whose first download is still queued can stream normally. Playlist and metadata edits require a connection.

Signing out stops playback, removes credentials, and hides the account. It **keeps the account's downloaded files and pending history**, and signing back into the same server and account unlocks them. This is app-level isolation, not encryption or DRM against the device owner. Signing out offline can't revoke the remote session until the server is reachable. If needed, use a password reset to revoke all sessions.

## Listening history

Listening time counts only active, non-buffering playback. Skipped seek distance doesn't count. History is checkpointed about every ten seconds and at track transitions. An abrupt process or power loss can lose the final uncommitted segment.

One play counts per session after `min(30 seconds, half the track duration)` of listening, with a minimum of 1 ms. Stats keep partial listening. Local outbox records are deleted only after the server acknowledges their event IDs. For date-range and clock behavior, see [API semantics](API.md) and [server details](../server/README.md).

## Verify downloads

In **Downloads**, choose **Verify downloads** to check cached audio against its SHA-256 checksum. This includes older downloads without Activity entries. The local-only scan works offline and hashes in a background isolate. It shows byte progress, checked-file counts, and an estimated time remaining once throughput is measured. Cancelling stops the scan but keeps completed checks. Leaving Downloads doesn't stop it.

Startup, normal sync, and retry passes check recorded identity, file existence, and size. They don't rehash the whole library. New and resumed downloads still pass full checksum verification before they become playable. So same-size damage to existing files is detected only when you run verification.

Results sort files into valid, invalid, and skipped. Invalid audio is removed from playable storage, but offline selections are kept. When connected, choose **Redownload corrupted files** to repair them through the normal download queue. Verification itself downloads nothing. Unrepaired failures stay held across restarts.

Repair keeps existing selections. It adds a track selection only for a damaged file that has no remaining selection. Unreadable or concurrently changed files are skipped so they can be checked again safely.
