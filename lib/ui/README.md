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
- Library search, albums/artists, metadata and immediate artwork replacement.
- Ordered playlists with unique entry IDs, explicit duplicates, drag handles
  and accessible move-up/down menus.
- Downloads show completed-track progress, pinned selections, storage totals,
  removal and retry through sync. The current core API does not expose partial
  audio-download byte counts; no invented byte progress is shown.
- Upload picker and desktop drop use persistent core jobs, acknowledged-byte
  progress, cancellation/retry. Cancelled jobs are re-enqueued as new uploads.
- Listening history/top lists and inclusive local-date range selection (server
  `to` is exclusive). Pending listening outbox counts are explained.
- Server login/logout, theme light/dark/system (session-local choice), device
  text scaling/reduced motion, labeled controls, Ctrl/Cmd shortcuts.

Tests: `test/ui/widgets_test.dart`, `test/ui/app_test.dart`. Test fixtures only
exist under `test/ui`; production screens contain no mock records.
