#!/bin/bash
# Score the detector against Eval/labels. See Eval/EvalMain.swift for flags.
#   ./Eval/eval.sh [--json out.json] [--baseline Eval/baseline.json]
#   ./Eval/eval.sh --draft ~/Movies/match.mov tennis > Eval/labels/match.json
set -e
cd "$(dirname "$0")/.."

OUT=".build/eval"
mkdir -p .build

# main.swift is required for top-level code. -Onone keeps the selftest asserts.
cp Eval/EvalMain.swift .build/main.swift

OPT=-O
[ "$1" = "--selftest" ] && OPT=-Onone

swiftc $OPT \
  Ribatto/Models.swift \
  Ribatto/Engine/AudioLoader.swift \
  Ribatto/Engine/RallyDetector.swift \
  Ribatto/Engine/SoundCheck.swift \
  .build/main.swift \
  -o "$OUT" 2>&1 | grep -v "warning:" | grep -v "^ *[0-9|]" | grep -v "^ *\`-" || true

"$OUT" "$@"
