# Offline and privacy

## Downloads

Download tracks, albums, or playlists explicitly. When connected, playlist selections follow server changes. Overlapping selections share one copy. Originals are never evicted silently.

Artwork has a separate, bounded 1 GiB cache per account. Artwork currently on screen is protected from speculative eviction. If artwork doesn't fit, placeholders are shown instead of repeatedly downloading and evicting it. A new foreground request or artwork revision can retry after a capacity miss.

Selected uploads are first copied into account-private staging storage (up to 1 GiB per file by default). Successful or cancelled jobs delete only these staged copies, never your originals. Budget staging space on top of downloads. Transfers run while the app is running and resume later; the app doesn't promise OS-scheduled transfers after it exits.

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
