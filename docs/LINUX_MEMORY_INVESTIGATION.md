# Linux memory investigation

This is the pre-change investigation at revision `cac628d`, not a benchmark of
all changes in this PR. The subsequent fix makes the system allocator the Linux
default, retains an opt-in mimalloc build, and bounds app-icon decoding. See
[Linux allocator selection](../linux/README.md#allocator-selection) for current
build instructions. References to unchanged code/defaults below describe the
investigation itself.

## Conclusion

The Linux-specific **process-wide mimalloc override is a measured contributor**, not just a suspected playback cache. Relinking the existing release runner without its mimalloc object reduced idle RSS by **84–99 MiB in two fresh-data-directory desktop comparisons**, and by **102 MiB with the existing local library**. No Dart code, Flutter engine, plugins, or renderer setting was changed for this comparison.

Immediate mimalloc purging saved about **44 MiB** in the fresh-directory comparison, consistent with the user's release-to-release result (~45 MiB). Purge delay therefore explains only part of the allocator difference. The remaining difference may include fragmentation, thread-local allocation behavior, and other reclamation policies; the experiment does not identify their individual shares.

Other verified differences are Linux's GTK/Mesa/LLVM/native graphics stack and its full system libmpv, versus Windows's packaged minimal audio-specific mpv build. Shared-library accounting also inflates an RSS-versus-private-working-set comparison. There is **no demonstrated unbounded leak**, and the complete Windows/Linux gap has not been quantified with equivalent Windows measurements.

## Environment and method

- Repository revision inspected: `cac628d`.
- Existing Flutter release bundle: Flutter 3.47.5, Dart 3.13.4, Linux x86-64.
- media_kit 1.2.6; media_kit_libs_linux 1.2.1; mimalloc 2.1.2.
- Host system mpv 0.41.0; Mesa 26.2.5; LLVM 23.1; NVIDIA libraries 615.78.08.
- Desktop tests: existing Wayland session, default Impeller OpenGLES renderer, 1.25 display scale.
- Read `/proc/<pid>/smaps_rollup` and `smaps`; values below are MiB, converted from the kernel's KiB counters.
- Copied the release executable into a temporary diagnostic bundle. For the glibc variant, replayed the generated Ninja link command using the **same compiled runner objects**, removing only `mimalloc/out/release/mimalloc.o`. Runtime assets and libraries were shared with the original bundle. Output and linker dependency-file handling were redirected/removed to avoid changing the production binary.
- Verified that the production executable and its diagnostic mimalloc copy have identical SHA-256 hashes after testing.
- No runtime defaults or application source code were changed.

### Fresh-directory is not signed-out

The initial experiments used fresh `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, and `XDG_CACHE_HOME` directories. However, Linux secure storage uses the shared session keyring: these runs recovered the existing account and populated the library. **They are cold local-cache/library-startup tests, not empty-library or login-screen tests.** Earlier progress messages calling them an “empty profile” should be read with this correction.

## 1. Controlled desktop allocator comparison

Each row is sampled 30 seconds after launch, before playback. Two independent fresh-directory runs were performed per default allocator variant.

| Allocator / local data | RSS | PSS | Private dirty | Total private resident |
|---|---:|---:|---:|---:|
| mimalloc, fresh directories, run 1 | 347.6 | 237.6 | 199.2 | 224.4 |
| mimalloc, fresh directories, run 2 | 360.7 | 250.7 | 212.4 | 237.4 |
| glibc, fresh directories, run 1 | 263.6 | 152.5 | 114.9 | 138.9 |
| glibc, fresh directories, run 2 | 261.5 | 150.5 | 112.9 | 136.9 |
| mimalloc, purge delay 0, fresh directories | 303.2 | 193.2 | 154.9 | 180.1 |
| mimalloc, existing library | 362.5 | 252.1 | 213.7 | 238.8 |
| glibc, existing library | 260.3 | 149.0 | 111.5 | 135.4 |

`Total private resident = Private_Clean + Private_Dirty`, not PSS.

**System libmpv is absent from the pre-playback mappings.** Thus the measured startup allocator penalty cannot be attributed to an active mpv demuxer or audio buffer. Image loading, Flutter, GTK, graphics drivers, and other native clients all share the overridden allocator.

Sources:

- `linux/CMakeLists.txt:86–92` explicitly links `MIMALLOC_LIB` into the executable.
- `media_kit_libs_linux-1.2.1/linux/CMakeLists.txt` downloads/builds mimalloc 2.1.2 and documents that this overrides the standard malloc interface.
- Executable dynamic symbols confirm that the ordinary bundle defines `malloc`; the relinked glibc diagnostic does not provide the mimalloc override.

Mimalloc's 64-bit default reserves 1 GiB arenas. Three such reservations explain the previously observed multi-GiB anonymous address-space region, **not multi-GiB RAM usage**. Neither reservation nor OS commitment is interchangeable with RSS.

## 2. Playback measurements

### Actual desktop, default allocator

One completed automated run measured:

| Stage | RSS | PSS |
|---|---:|---:|
| Library idle, 30 seconds after launch | 337.1 | 226.6 |
| After 60 seconds playing | 438.1 | 311.4 |
| Largest sampled value across five subsequent Next commands | 480.0 | 351.7 |
| Ten seconds after Stop | 462.9 | 334.4 |

This reproduces the approximate reported footprint. It is **not** a paired glibc playback comparison. Two subsequent desktop automation attempts did not establish playback and were excluded. Desktop input automation was then stopped in favor of an isolated display.

Stopping playback retains the player instance by design, so the final number is not a post-disposal measurement.

### Isolated-display comparison: separate graphics workload

A private Xvfb display and a null audio sink allowed playback tests without interacting with the desktop. The same downloaded track was selected initially in all three runs (verified through MPRIS metadata), followed by the same sequence of library-row selections. Playback was verified through MPRIS. No allocator benchmark ran concurrently with another.

**Xvfb does not provide the desktop's accelerated graphics path.** Its logs report a missing DRI3 device; Mesa/LLVM software rendering adds substantial allocations. Do not compare these absolute values directly with desktop results or claim the same savings on a normal display.

| Allocator | Idle RSS | RSS after 60 seconds playing | RSS ten seconds after Stop |
|---|---:|---:|---:|
| mimalloc default | 602.8 | 711.9 | 737.0 |
| glibc | 363.4 | 471.3 | 551.2 |
| mimalloc, purge delay 0 | 541.2 | 648.0 | 675.0 |

The allocator effect persists under this different workload. However, these ~2.5-minute sessions are not a leak/long-playback qualification test, and not every library-row selection was separately verified through metadata. All three variants successfully entered playback and completed the sequence without a process crash.

## 3. Native allocation traces

Heaptrack 1.5.0 was extracted into a temporary directory, not installed system-wide.

- Ordinary `LD_PRELOAD` interception alone is insufficient for the executable's static malloc override. The original allocator was profiled using heaptrack's injection mode; the glibc variant used normal preload mode.
- Desktop startup traces showed approximately **50 MB tracked peak native allocations** with the original allocator and **56 MB** with glibc. Large allocation groups included Mesa/Gallium, GTK/Cairo/pixman surfaces, Flutter, and font handling.
- The much larger RSS difference, despite similarly sized tracked peaks, supports allocator overhead/retention as a contributor. This is not a complete native-heap census: direct `mmap`, Dart VM heap pages, driver mappings, and interception limitations remain.
- The successful isolated-display **glibc playback** trace reported approximately **342 MB tracked peak allocations**. Major allocation sites included:
  - ~211 MB grouped at an address inside LLVM. Mapping lookup plus `addr2line` resolved it to `llvm::SmallVectorBase<unsigned int>::grow_pod`; callers run through Mesa context/rendering paths.
  - ~68 MB grouped at a Gallium allocation site.
  - ~19 MB at `av_buffer_realloc`, with `av_packet_make_refcounted → av_read_frame → libmpv` stacks.
  - ~12 MB at `av_malloc`, including a ~10.5 MB group from mpv.
  - ~17 MB at a Flutter allocation site and ~2.3 MB at another mpv allocation site.

These grouped allocation-site peaks are **not necessarily simultaneous** and must not simply be added. Heaptrack's output uses decimal MB; the process tables above use MiB. The Mesa/LLVM numbers describe the isolated software-rendered workload, not proof that the normal desktop consumes the same amounts.

The original-allocator isolated-display trace did not successfully start playback; it is only valid for startup/rendering analysis. Its startup trace also showed large Mesa/LLVM allocations.

Processes were terminated after measurement. Consequently, heaptrack's “leaked”/not-freed-at-end totals are **not evidence of leaks**. Instrumented RSS is also inflated by profiler overhead and is excluded from allocator benchmark tables.

## 4. Linux and Windows playback dependencies differ

The `media_kit_libs_audio` umbrella dependency does not provide identical native libraries on both platforms:

- Linux's plugin bundles no mpv library; media_kit loads the host's system `libmpv.so`.
- Windows's audio plugin bundles a minimal audio-specific mpv/FFmpeg build (`mpv-dev-x86_64-20230924-git-652a1dd.7z`). It does not add the Linux runner's mimalloc override.
- A separate Python/ctypes probe measured RSS increasing from 11,392 KiB to 55,064 KiB merely by loading this host's system libmpv, and to 60,928 KiB after initialization. This is an isolated loading-cost measurement, **not an additive 43 MiB estimate for Yun**, which already loads some shared dependencies.

Yun creates one lazy, guarded `Player()` and reuses it. It opens one media item, not one decoder per queued track. media_kit disables video (`vid=no`, `vo=null`, `audio-display=no`). Merely finding video-capable libraries in memory does not establish active video decoding.

The installed dependency enables disk caching and sets 32 MiB forward/backward demuxer limits. Those are not eager 64 MiB RAM allocations; with disk caching enabled, mpv retains packet metadata in RAM while payload can go to disk. The playback trace confirms buffers in the tens-of-megabytes range for the tested files, not hundreds of megabytes in one eager audio allocation.

References:

- `lib/services/playback_engine.dart`: `_nativePlayer`, guarded initialization, single-media open, and disposal.
- `media_kit-1.2.6/lib/src/player/native/core/native_library.dart`.
- `media_kit-1.2.6/lib/src/player/native/player/real.dart`.
- `media_kit_libs_windows_audio-1.0.9/windows/CMakeLists.txt`.

## 5. Artwork and app-code audit

No app-level object collection was identified that explains the entire native gap.

- `lib/ui/track_widgets.dart` supplies DPR-scaled `cacheWidth` to track images.
- The eight artwork files fetched in a fresh-directory startup were 640–1200 pixels per dimension; the largest was a 1200×1200 PNG (~2.23 MiB encoded). This sample does not contain an exceptionally huge cover.
- `ArtworkCache`'s 1 GiB budget is a **disk** budget. Startup scans metadata, rather than preloading all images. Three active downloads and a 10 MiB encoded-image cap bound that path, though temporary copies can add memory.
- The Flutter image cache retains its default 100 MiB keep-alive budget. That is a limit, not evidence the current session fills it, and not a limit on every native image/renderer allocation.
- The 1024×1024 app icon is displayed at 32/48 logical pixels without a decode-size hint (`lib/ui/app.dart`). Its full RGBA image is ~4 MiB: a concrete small optimization, **not the explanation for a 400 MiB gap**.
- Linux MPRIS publishes a local artwork URI; the inspected code does not decode full artwork in Yun for MPRIS. Tray decoding uses a 64×64 image and explicitly disposes native image/codec objects.

## Recommendations

1. Treat **Linux allocator choice/version/reclamation policy** as the primary measured optimization target. An opt-in build switch would make glibc-versus-mimalloc regression tests reproducible without changing the default.
2. Before changing the default, compare longer playback/seek/track-switch sessions, CPU usage, latency, and crash behavior. The current build comment cites media_kit's allocator recommendation, so a short RSS improvement is not enough to remove it blindly.
3. Keep default rendering for now. User tests found neither software rendering nor disabling Impeller reduced memory. Xvfb measurements demonstrate why software fallback can itself be expensive.
4. Add a decode-size hint for the app icon as a separate small optimization, not as a purported main fix.
5. An exact cross-platform explanation still requires equivalent private-memory and playback-library measurements on Windows. This investigation establishes Linux contributors but does not manufacture a complete 130-versus-530 MiB decomposition.

## Evidence retained

- Numeric snapshots: `docs/linux-memory-samples.csv`.
- Local diagnostic scripts, relinked executables, per-stage mappings, logs, and heaptrack captures: `/tmp/yun-investigation/` (temporary, not committed).
- Relevant trace summaries: `mimalloc-peaks.txt`, `empty-peaks2.txt`, and `headless-glibc-peaks.txt` in that directory.

Failed playback attempts and the initial truncated heaptrack recording are excluded from the numeric evidence file. Production binaries and settings were not changed as an optimization. Normal app runs can still write their ordinary cache/history/window-state data.
