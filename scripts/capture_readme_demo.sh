#!/bin/zsh
# Renders the README's macOS walkthrough GIF without touching the screen.
# The ReadmeDemoFramesTests case hosts the real ContentView offscreen, drives
# it through the store one step at a time, and writes a PNG per step plus an
# ffmpeg concat manifest; this script stitches them into the GIF.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT_DIR/docs/assets/capture-queue-workflow-macos.gif}"
FRAMES_DIR="$(mktemp -d /tmp/iLabel-Studio-readme-frames.XXXXXX)"
WIDTH="${GIF_WIDTH:-1200}"
trap 'rm -rf "$FRAMES_DIR"' EXIT

cd "$ROOT_DIR"
ILABEL_DEMO_FRAMES_DIR="$FRAMES_DIR" swift test --filter ReadmeDemoFramesTests

# Two passes: a shared palette keeps the flat UI colors clean at GIF depth.
ffmpeg -y -loglevel error -f concat -safe 0 -i "$FRAMES_DIR/frames.txt" \
  -vf "scale=${WIDTH}:-1:flags=lanczos,palettegen=max_colors=256:stats_mode=diff" \
  "$FRAMES_DIR/palette.png"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$FRAMES_DIR/frames.txt" -i "$FRAMES_DIR/palette.png" \
  -lavfi "scale=${WIDTH}:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 "$OUTPUT"

echo "Wrote $OUTPUT"
