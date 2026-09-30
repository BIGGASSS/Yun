# Client integration API

Import `package:yun/core/app_controller.dart` (re-exports models). `AppController` is a `ChangeNotifier`. Create once, `await app.initialize()`, use `ListenableBuilder`/Provider, and dispose at shutdown. Native playback is initialized lazily on first play. `lib/main.dart` owns initialization, lifecycle checkpoints, orderly exit, and persistent theme/playback settings. All async operations throw actionable exceptions; UI should catch and show them. `error` also reports background failures, except transient connection errors/timeouts: these only set `isOffline`, avoiding repeated banners during app resume and automatic retries. Explicit actions still throw so the UI can report their failure. Authentication, server, certificate and storage errors remain visible. No UI dependency beyond Flutter foundation.

## AppController
- `AppController({ApiClient? api, Future<Directory> Function()? storageDirectory, CacheDatabase Function(File)? databaseFactory, PlaybackEngine? playbackEngine, SystemMediaControls? systemControls, bool enableSystemControls = true, bool automaticRefresh = true, int artworkCacheMaxBytes = 1073741824})`. Production defaults; injectable adapters permit native-free tests.
- `Future<void> initialize()` restores last signed-in account from secure storage, opens its isolated cache even offline, then attempts network sync.
- `bool initialized, busy, isAuthenticated, isOffline`; `String? error`; `Account? account` (`server`, `userId`, `username`).
- `List<Track> tracks`, `List<Playlist> playlists`; `List<UploadJob> uploads`; `Set<String> downloadedTrackIds`; `List<PinSelection> pins`; `int pendingEventCount`.
- `Future<void> login(String server, String username, String password)`; `Future<void> logout()` retains files/outbox but locks access until reauthentication.
- `Future<void> refresh()` syncs library cursor, retries event outbox, uploads and pinned downloads. `Future<void> flushOutbox()` sends pending segments independently. `clearError()`. Background retry interval is 30 seconds; failed uploads reconcile their server offset on retry.
- `Track? trackById(String id)`; `String? localPath(String trackId)`; `Future<String> audioUrl(String trackId)`; `Future<Map<String,String>> authorizationHeaders()`.
- `Future<void> play(Track track, {List<Track>? queue})`; `PlaybackController get playback` (also a ChangeNotifier; app forwards changes).
- `Future<Track> updateTrack(Track track, Map<String,dynamic> changes)`, `deleteTrack(String id)`, `Future<Track> setArtwork(Track track, Uint8List bytes, {String mimeType = 'image/jpeg'})`.
- `Future<Playlist> createPlaylist(String name)`, `savePlaylist(Playlist playlist, {String? name, List<PlaylistEntry>? entries})`, `deletePlaylist(Playlist playlist)`; entry IDs generated with `newId()` (duplicates of a track allowed).
- `Future<void> pinTrack(String id, {bool pinned = true})`, `pinAlbum(String album, String artist, {bool pinned = true})`, `pinPlaylist(String id, {bool pinned = true})`; `bool isPinned(String type, String id)`; pins persist and referenced files are reconciled after sync. Album pin identity: `albumPinId(album, artist)`.
- `Future<void> enqueueUpload(String path)`, `cancelUpload(String id)`, `retryUpload(String id)`; persistent jobs include byte progress/status/error. Enqueue copies the source into a durable account-private spool before returning, bounded by `maxUploadBytes` (default 1 GiB). Await it while picker sandbox access is available. Successful/cancelled owned copies are removed; external originals are never deleted.
- `String? artworkPath(Track track)`, `Future<String?> getArtwork(Track track)`; account/revision-scoped local-first cache (1 GiB budget), safe through logout and late requests. Capacity/eviction misses do not refill on polling or notifications. `VoidCallback? retainArtwork(Track track)` protects resident artwork for mounted foreground consumers; release on disposal or identity changes. Duplicate consumers share demand; only a new demand after all consumers release retries capacity misses. Oversized revisions stay suppressed across demand changes. `Future<String?> retryArtwork(Track track)` explicitly retries a suppressed revision, still respecting capacity; never call it from automatic refresh. Cache reopen/new revisions reset suppression, and successful manual replacement clears it.
- `DownloadProgress downloadProgress(Track track)`, `Future<void> retryDownloads()`; byte-level queued/downloading/verifying/downloaded/failed progress and errors. Download selections remain durable.
- `Future<ServerStats> loadStats({DateTime? from, DateTime? to})`; `ServerStats? stats`.
- `Future<void> shutdown()` flushes playback segments and closes account resources, retaining active credentials for the next launch. Await at orderly process shutdown; `dispose()` also initiates cleanup.

## PlaybackController
`Track? currentTrack`; `List<Track> queue`; `int index`; `bool isPlaying, isBuffering, shuffle`; `Duration position, duration`; `RepeatMode repeatMode` (`off`, `all`, `one`); `String? error`.
`Future<void> playQueue(List<Track> tracks, {int? index})`, `play()`, `pause()`, `toggle()`, `next()`, `previous()`, `seek(Duration position)`, `stop()`, `checkpoint()`, `shutdown()`; `void setShuffle(bool)`, `setRepeat(RepeatMode)`. UI may listen directly or via app. `checkpoint()` persists measured time without pausing (useful on application lifecycle transitions). The controller also checkpoints automatically every 10 seconds and on pause/buffering/seek/track transitions.

Without an explicit `index`, `playQueue` starts at a random track when shuffle is enabled, otherwise the first track. An explicit index always selects that entry. Queue order, shuffle, repeat, and volume preferences are preserved.

`double volume` (0–100, initially 100), `bool isMuted`, `Future<void> setVolume(double)`,
`toggleMute()`: serialized app-local loudness; mute restores the last positive level.
Percentages approximate perceived loudness: 50% is roughly half as loud as 100%,
25% half as loud as 50% (−10 dB per halving). The native adapter compensates for
mpv's cubic mixer curve; UI and saved settings retain the percentage, not the
native mixer value. 0% is silence and 100% is unchanged audio. This is a perceptual
approximation, not track loudness normalization. Existing saved percentages are
retained, so intermediate settings play louder than with the old curve.
Finite input is clamped; nonfinite input is rejected. Before first playback these
commands do not initialize audio; the saved gain applies before audio opens.
Native failures do not publish or persist an unapplied value.

Bootstrap restores device-local `PlaybackSettings` before constructing the app:
desktop volume (including mute and its last positive restore level), shuffle, and
repeat survive restarts and account changes. Android retains OS-managed volume;
shuffle/repeat persist there too. Queue, position, and playing state are not saved
and restoration never starts audio. Untouched volume leaves native defaults alone.
The core accepts `initialSettings` / `saveSettings`; AppController forwards
`playbackSettings` / `savePlaybackSettings`. Standalone/test controllers default
to in-memory preferences unless these are injected.

Changes eagerly queue ordered, complete snapshots in SharedPreferences under
`playback.settings`, independently of audio commands. `flushSettings()` drains
accepted commands and writes; lifecycle backgrounding and shutdown drain too.
Storage errors appear in `playback.error` without reverting successful audio
changes; another setting command retries (including the same value). Malformed
stored fields fall back safely. Preferences contain no track/account information.

## CollectionSettingsController

Bootstrap loads device-local sorting preferences from `collections.sorting` and
shares the controller with browsing screens. Library tracks, album details,
artist details, playlist overview, playlist entries, and the Add tracks picker
remember independent sort fields and directions. Defaults retain title order,
album order, and playlist order as appropriate. Missing preferences use defaults;
malformed JSON or a non-object stored value fails bootstrap without rewriting it.
Within a valid object, unknown or corrupt fields fall back independently without
affecting valid settings.

Edits update the view immediately and queue complete snapshots in order. Storage
failures are surfaced by the initiating UI action and retained for `flushSettings()`
until a later complete snapshot saves successfully. Later edits retry the current
snapshot. Lifecycle checkpoints and orderly shutdown drain accepted writes;
unresolved save failures prevent orderly shutdown from reporting success.
Preferences contain no collection IDs, search queries, selections, or playback
state, and never change the persisted entry order of a playlist.

## DesktopController

Bootstrap owns a separate desktop-only `DesktopController`, injected into YunApp.
It serializes window visibility, close requests, preference writes and shutdown.
`desktop.closeBehavior` is an account-independent SharedPreferences enum name;
missing/unknown values default to `quit`. Writes publish only after success.

`requestWindowClose()` applies that preference. `minimizeToTray()` checkpoints
without stopping playback, closing databases, or changing credentials/queues.
`showWindow()` restores/focuses. `quit()` and `requestApplicationExit()` always
await account shutdown and pending settings, regardless of close preference.
A failed `prepareExit` settings preflight leaves the account running and can be
retried after a successful save. Failed account shutdown leaves the window
visible and prohibits further hiding; it does not pretend the core's memoized
shutdown can be retried. OS force termination remains outside orderly-shutdown
guarantees.

`DesktopHost` isolates native APIs. The adapter uses pinned `window_manager`,
`tray_manager` on Windows/macOS, and a direct Linux StatusNotifierItem/DBusMenu.
Primary activation restores/focuses; right-click exposes Show / Quit. Linux
advertises `ItemIsMenu=false`, requires acknowledged registration with the current
watcher plus a live host, and re-registers when the watcher restarts. Windows has
a pre-engine WM_CLOSE bridge and checked shell-icon probe. Loss monitoring
restores hidden windows.
Windows probes intentionally match tray_manager 0.5.3's root-window/icon ID pair;
revalidate that contract before upgrading the plugin. macOS Dock reopening
reconciles hidden state through native focus events. Touch/web never construct
this adapter. Retry retains interception until old-account shutdown completes.

## Models
Track: id/title/artist/album/albumArtist/trackNumber/discNumber/durationMs/sizeBytes/sha256/mimeType/hasArtwork/revision/createdAt; `Duration duration`.
Playlist: id/name/revision/entries/updatedAt. PlaylistEntry: id/trackId; constructors and JSON converters supplied.
UploadJob: id/localPath/filename/sizeBytes/offset/remoteId/status/error; `double progress`. Status string: queued/uploading/completing/done/failed/cancelled.
ServerStats: listenedMs/playCount/topTracks/topArtists/topAlbums/history (typed models); JSON converters. Account and pin/job persistence are account-scoped.

## Native integration / validation

The native adapters use media_kit, audio_session, audio_service on Android/macOS, audio_service_mpris on Linux, and smtc_windows on Windows. Initialize Flutter bindings before `initialize()`. The core lazily owns native initialization; do not separately call `AudioService.init()` or `SMTCWindows.initialize()` in main. The platform owner must supply media_kit audio libraries, Android audio_service activity/service/receiver declarations and foreground-media permissions, macOS network/keychain entitlements, Linux libmpv and Secret Service, and the Windows SMTC Rust build toolchain. OS integration failures are surfaced in `playback.error` without disabling supported playback. Windows currently exposes transport/shuffle/repeat buttons and timeline (the plugin does not expose absolute seek requests).

`test/core/` covers token rotation/replay, offline account isolation/restoration, cursor transactions and tombstones, acknowledged-only outbox removal, range downloads and checksum rejection, durable upload offsets, pin reference counts, queue/shuffle/repeat, and monotonic time accounting. Tests inject network/credentials/player and do not initialize native plugins.

Offline availability does not imply a valid access token. Existing signed-in sessions can always play verified cached files. Metadata/playlist edits require the server and surface revision conflicts rather than silently overwriting. Logout retains cache/files/event segments but removes credentials and the active-account marker. Same-account login unlocks and retries them.

The native adapter ignores media_kit's FFmpeg TCP diagnostics while opening or
playing a local source. Its error stream includes network log messages that can
arrive after an earlier stream has closed; treating those as a local file failure
would stop downloaded audio and require the server for recovery. Actual local
file/decoder failures and remote stream errors still use playback recovery.
