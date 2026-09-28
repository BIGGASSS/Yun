#!/usr/bin/env bash
# Synthetic audio only; FFmpeg is needed to regenerate, not to run cargo test.
set -euo pipefail
cd "$(dirname "$0")/../tests/fixtures"
for extension in mp3 flac m4a ogg opus aac aiff; do
  ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i 'sine=frequency=440:duration=0.25:sample_rate=48000' \
    -metadata title='Fixture title' -metadata artist='Fixture artist' \
    -metadata album='Fixture album' -metadata album_artist='Fixture album artist' \
    -metadata track=3 -metadata disc=2 "tone.$extension"
done
