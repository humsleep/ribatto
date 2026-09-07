#!/bin/bash
# Build and run the player-tracking validator against a video file.
#   ./Tools/track_validate.sh ../sample.mov 3 tennis
#
# Measures what PlayerTracker actually does on real footage: whether Vision
# sees anyone, how long a seeded track holds, what each stage costs, and which
# stage carries the load. Reads only — changes nothing.
set -e
cd "$(dirname "$0")/.."

OUT=".build/track_validate"
mkdir -p .build

# main.swift is required for top-level code
cp Tools/TrackMain.swift .build/main.swift

swiftc -O \
  Ribatto/Models.swift \
  Ribatto/Engine/AudioLoader.swift \
  Ribatto/Engine/RallyDetector.swift \
  Ribatto/Engine/ClipExporter.swift \
  Ribatto/Engine/SmartCrop.swift \
  Ribatto/Engine/PlayerTracker.swift \
  Ribatto/Engine/FrameSequence.swift \
  Ribatto/Engine/HighlightMerger.swift \
  Ribatto/Engine/ReelBuilder.swift \
  Ribatto/Engine/VideoProbe.swift \
  .build/main.swift \
  -o "$OUT" 2>&1 | grep -v "warning:" | grep -v "^ *[0-9|]" | grep -v "^ *\`-" || true

"$OUT" "$@"
