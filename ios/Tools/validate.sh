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
