# Yun UI

Entry point: `YunApp(controller: appController)` from `lib/ui/app.dart`.
The caller owns `AppController.initialize()` and disposal. All library, playback,
playlist, transfer, account and statistics operations use the real controller;
there is no parallel network/cache state in the UI.

UI package imports: `flutter`, `file_picker: ^10.3.10` (the `FilePicker.platform`
API), `desktop_drop: ^0.8.4`. File picker 13 has an incompatible static API; pin
the specified major. Core dependencies must also be installed before running
`flutter test test/ui` or analyzing UI.

- Narrow windows: bottom destinations, mini-player, full now-playing sheet.
- Wide windows: NavigationRail (extended at 1320px), persistent player, optional
  300px queue at 1180px and above. Large text falls back to simpler layouts.
- Linux/macOS/Windows: app-local 0–100% volume and mute in the player and
  now-playing sheet. Compact windows use a Volume button/dialog. Muting remembers
  the previous positive level; sliders support keyboard input and spoken percent
  values. Volume/mute (including the unmute level), shuffle, and repeat persist
  across restarts. Android keeps its existing system-volume controls, even on
  wide screens, and remembers shuffle/repeat. Queue/position do not auto-restore.
- Desktop's expanded player uses balanced side zones around centered transport,
  a seek column capped at 640px, slim slider tracks, and local vector glyphs
  instead of icon-font glyphs. Selected shuffle/repeat have a persistent highlight.
  Touch platforms retain their original layout, including wide Android tablets.
- Desktop-only **Settings → Window behavior**: saved Quit (default) / Minimize to
  tray close policy, plus explicit Minimize and Quit buttons. Left-clicking the
  branded tray icon restores/focuses the window; right-click opens Show / Quit.
  Quit and macOS Cmd-Q bypass the hide policy. Missing
  trays keep the window visible, retain the preference, and expose a dismissible
  error. Controls are platform-gated even at narrow desktop / wide mobile sizes.
  Bootstrap supplies the optional `YunApp.desktop` controller.
- Library search, albums/artists, metadata and immediate artwork replacement.
  Track sorting and checkbox multiselection support filtered select-all, bulk
  playback, playlist addition, offline pinning and confirmed deletion.
- Playlists and their entries support sorting, multiselection and select-all.
  Sorting is view-only; drag handles and move-up/down menus edit saved order
  only in ascending playlist-order view. Bulk removal preserves library tracks.
  Add tracks offers sorting and filtered select-all, excludes existing members,
  and adds each track at most once. Legacy repeated entries remain removable;
  new repeats are not offered, including additions from Library.
- Downloads show per-track byte progress, queued/verifying/failed states, pinned
  selections, storage totals, removal and retries. Artwork is cached privately
  and remains visible offline. Mounted artwork consumers share revision-scoped
  demand and protect resident images from background eviction. Capacity misses
  remain placeholders for that demand rather than refetching on cache, busy or
  connectivity notifications; disposing every consumer allows new demand.
- Upload picker and desktop drop use persistent core jobs, acknowledged-byte
  progress, cancellation/retry. Sources are copied into durable account-private
  staging storage. Cancelled uploads require selecting the source file again;
  macOS drop bookmarks remain scoped until the copy completes.
- Listening history/top lists and inclusive local-date range selection (server
  `to` is exclusive). Pending listening outbox counts are explained.
- Server login/logout, theme light/dark/system (persisted by bootstrap), device
  text scaling/reduced motion, labeled controls, Ctrl/Cmd shortcuts.

Tests: `test/ui/` and `test/core/app_artwork_test.dart`. The desktop player has
layout/interaction tests and dark/light/840px goldens in `test/ui/goldens/`.
Goldens intentionally use Flutter's deterministic test font, not desktop fonts;
regenerate only after visual review with
`fvm flutter test test/ui/player_bar_screenshot_test.dart --update-goldens`.
Production screens contain no mock records; fixtures live only in test directories.
