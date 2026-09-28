# Client integration API

Import `package:yun/core/app_controller.dart` (re-exports models). `AppController` is a `ChangeNotifier`. Create once, `await app.initialize()`, use `ListenableBuilder`/Provider, and dispose at shutdown. Native playback is initialized lazily on first play. All async operations throw actionable exceptions; UI should catch and show them. `error` also reports background failures. No UI dependency beyond Flutter foundation.

## AppController
- `AppController({ApiClient? api, Future<Directory> Function()? storageDirectory, CacheDatabase Function(File)? databaseFactory, PlaybackEngine? playbackEngine, SystemMediaControls? systemControls, bool enableSystemControls = true, bool automaticRefresh = true})`. Production defaults; injectable adapters permit native-free tests.
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
- `Future<void> enqueueUpload(String path)`, `cancelUpload(String id)`, `retryUpload(String id)`; persistent jobs include byte progress/status/error.
- `Future<ServerStats> loadStats({DateTime? from, DateTime? to})`; `ServerStats? stats`.
- `Future<void> shutdown()` flushes playback segments and closes account resources, retaining active credentials for the next launch. Await at orderly process shutdown; `dispose()` also initiates cleanup.

## PlaybackController
`Track? currentTrack`; `List<Track> queue`; `int index`; `bool isPlaying, isBuffering, shuffle`; `Duration position, duration`; `RepeatMode repeatMode` (`off`, `all`, `one`); `String? error`.
`Future<void> playQueue(List<Track> tracks, {int index = 0})`, `play()`, `pause()`, `toggle()`, `next()`, `previous()`, `seek(Duration position)`, `stop()`, `checkpoint()`, `shutdown()`; `void setShuffle(bool)`, `setRepeat(RepeatMode)`. UI may listen directly or via app. `checkpoint()` persists measured time without pausing (useful on application lifecycle transitions). The controller also checkpoints automatically every 10 seconds and on pause/buffering/seek/track transitions.

## Models
Track: id/title/artist/album/albumArtist/trackNumber/discNumber/durationMs/sizeBytes/sha256/mimeType/hasArtwork/revision/createdAt; `Duration duration`.
Playlist: id/name/revision/entries/updatedAt. PlaylistEntry: id/trackId; constructors and JSON converters supplied.
UploadJob: id/localPath/filename/sizeBytes/offset/remoteId/status/error; `double progress`. Status string: queued/uploading/completing/done/failed/cancelled.
ServerStats: listenedMs/playCount/topTracks/topArtists/topAlbums/history (typed models); JSON converters. Account and pin/job persistence are account-scoped.

## Native integration / validation

The native adapters use media_kit, audio_session, audio_service on Android/macOS, audio_service_mpris on Linux, and smtc_windows on Windows. Initialize Flutter bindings before `initialize()`. The core lazily owns native initialization; do not separately call `AudioService.init()` or `SMTCWindows.initialize()` in main. The platform owner must supply media_kit audio libraries, Android audio_service activity/service/receiver declarations and foreground-media permissions, macOS network/keychain entitlements, Linux libmpv and Secret Service, and the Windows SMTC Rust build toolchain. OS integration failures are surfaced in `playback.error` without disabling supported playback. Windows currently exposes transport/shuffle/repeat buttons and timeline (the plugin does not expose absolute seek requests).

`test/core/` covers token rotation/replay, offline account isolation/restoration, cursor transactions and tombstones, acknowledged-only outbox removal, range downloads and checksum rejection, durable upload offsets, pin reference counts, queue/shuffle/repeat, and monotonic time accounting. Tests inject network/credentials/player and do not initialize native plugins.

Offline availability does not imply a valid access token. Existing signed-in sessions can always play verified cached files. Metadata/playlist edits require the server and surface revision conflicts rather than silently overwriting. Logout retains cache/files/event segments but removes credentials and the active-account marker. Same-account login unlocks and retries them.
