#!/usr/bin/env bash
# Fetch the English speech model (Parakeet TDT-CTC 110M, CoreML) that ships inside the
# iOS app bundle. Output: iOS/Models/parakeet-tdt-ctc-110m-coreml (gitignored).
# Re-running is a no-op once every file is present.
set -euo pipefail

REPO="FluidInference/parakeet-tdt-ctc-110m-coreml"
REVISION="${MODEL_REVISION:-main}"
# The components FluidAudio's AsrModels.loadLocal(version: .tdtCtc110m) reads.
COMPONENTS=(Preprocessor.mlmodelc Decoder.mlmodelc JointDecision.mlmodelc parakeet_vocab.json)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Models/parakeet-tdt-ctc-110m-coreml"
STAMP="$ROOT/Models/.parakeet-tdt-ctc-110m-$REVISION.complete"

if [[ -f "$STAMP" ]]; then
    echo "Speech model already present: $DEST"
    exit 0
fi

mkdir -p "$DEST"
LISTING="$(mktemp)"
trap 'rm -f "$LISTING"' EXIT

curl -fsSL --retry 3 "https://huggingface.co/api/models/$REPO/tree/$REVISION?recursive=true" -o "$LISTING"

# One "path<TAB>size" line per file under the components we need.
FILES="$(python3 - "$LISTING" "${COMPONENTS[@]}" <<'PY'
import json, sys
entries = json.load(open(sys.argv[1]))
components = sys.argv[2:]
for entry in entries:
    if entry.get("type") != "file":
        continue
    path = entry["path"]
    if any(path == c or path.startswith(c + "/") for c in components):
        print(f"{path}\t{entry.get('size', 0)}")
PY
)"

for component in "${COMPONENTS[@]}"; do
    if ! grep -q "^$component" <<<"$FILES"; then
        echo "error: $component not found in $REPO@$REVISION" >&2
        exit 1
    fi
done

total=0
while IFS=$'\t' read -r path size; do
    target="$DEST/$path"
    total=$((total + size))
    if [[ -f "$target" && "$(stat -f%z "$target" 2>/dev/null || stat -c%s "$target")" == "$size" ]]; then
        continue
    fi
    mkdir -p "$(dirname "$target")"
    echo "Downloading $path"
    curl -fL --retry 3 --progress-bar "https://huggingface.co/$REPO/resolve/$REVISION/$path" -o "$target"
done <<<"$FILES"

touch "$STAMP"
echo "Speech model ready: $DEST ($((total / 1000000)) MB)"
