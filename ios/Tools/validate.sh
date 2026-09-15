#!/bin/bash
# Build and run the detection validator against a video file.
#   ./Tools/validate.sh ~/Movies/badminton.mov badminton
set -e
cd "$(dirname "$0")/.."

OUT=".build/validate"
mkdir -p .build

# main.swift is required for top-level code
cp Tools/ValidateMain.swift .build/main.swift

swiftc -O \
  Ribatto/Models.swift \
  Ribatto/Engine/AudioLoader.swift \
  Ribatto/Engine/RallyDetector.swift \
  Ribatto/Engine/SoundCheck.swift \
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
