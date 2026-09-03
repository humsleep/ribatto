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
  Vollio/Models.swift \
  Vollio/Engine/AudioLoader.swift \
  Vollio/Engine/RallyDetector.swift \
  Vollio/Engine/ClipExporter.swift \
  Vollio/Engine/SmartCrop.swift \
  Vollio/Engine/PlayerTracker.swift \
  Vollio/Engine/FrameSequence.swift \
  Vollio/Engine/HighlightMerger.swift \
  Vollio/Engine/ReelBuilder.swift \
  Vollio/Engine/VideoProbe.swift \
  .build/main.swift \
  -o "$OUT" 2>&1 | grep -v "warning:" | grep -v "^ *[0-9|]" | grep -v "^ *\`-" || true

"$OUT" "$@"
