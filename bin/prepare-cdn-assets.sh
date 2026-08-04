#!/usr/bin/env bash
# Prepare a reviewable CDN staging tree from the resources that are safe to publish.
# The 107/common split is intentionally explicit: Assets.xcassets is mostly flat,
# so this script never guesses which account type owns an image.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="$ROOT/CDNAssets"
MODE="all"

usage() {
  cat >&2 <<'EOF'
usage: bin/prepare-cdn-assets.sh [--output <dir>] [--sample]

Copies publishable resources into an explicit CDN staging tree:
  common/  PNGs from Assets.xcassets (module remains in the path)
  gif/     Sources/Assets/GIFs
  svga/    Sources/Assets/SVGA

107-specific images must be moved from common/ to 107/ after review; the
xcassets source tree does not contain enough information to infer that split.
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --sample)
      MODE="sample"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      ;;
  esac
done

if [[ "$OUTPUT_ROOT" != /* ]]; then
  OUTPUT_ROOT="$ROOT/$OUTPUT_ROOT"
fi

mkdir -p "$OUTPUT_ROOT/common" "$OUTPUT_ROOT/107" "$OUTPUT_ROOT/gif" "$OUTPUT_ROOT/svga"

copy_file() {
  local source="$1"
  local destination="$2"
  mkdir -p "$(dirname "$destination")"
  cp "$source" "$destination"
}

if [[ "$MODE" == "sample" ]]; then
  # One file per module/type gives a quick, representative upload test.
  copy_file "$ROOT/Sources/Assets.xcassets/authLoginBackground.imageset/authLoginBackground@3x.png" \
            "$OUTPUT_ROOT/common/auth/authLoginBackground@3x.png"
  copy_file "$ROOT/Sources/Assets.xcassets/liveBackground.imageset/liveBackground@3x.png" \
            "$OUTPUT_ROOT/common/live/liveBackground@3x.png"
  copy_file "$ROOT/Sources/Assets.xcassets/partyRoomBg.imageset/partyRoomBg@3x.png" \
            "$OUTPUT_ROOT/common/party/partyRoomBg@3x.png"
  copy_file "$ROOT/Sources/Assets/GIFs/pk-progress-win.webp" \
            "$OUTPUT_ROOT/gif/pk-progress-win.webp"
  copy_file "$ROOT/Sources/Assets/GIFs/diamond-yellow.gif" \
            "$OUTPUT_ROOT/gif/diamond-yellow.gif"
  copy_file "$ROOT/Sources/Assets/SVGA/pk/pk-countdown-5s.svga" \
            "$OUTPUT_ROOT/svga/pk/pk-countdown-5s.svga"
else
  while IFS= read -r -d '' source; do
    imageset="$(basename "$(dirname "$source")" .imageset)"
    copy_file "$source" "$OUTPUT_ROOT/common/$imageset/$(basename "$source")"
  done < <(find "$ROOT/Sources/Assets.xcassets" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -print0)

  while IFS= read -r -d '' source; do
    copy_file "$source" "$OUTPUT_ROOT/gif/$(basename "$source")"
  done < <(find "$ROOT/Sources/Assets/GIFs" -type f ! -name '.DS_Store' ! -name 'Contents.json' -print0)

  while IFS= read -r -d '' source; do
    relative="${source#"$ROOT/Sources/Assets/SVGA/"}"
    copy_file "$source" "$OUTPUT_ROOT/svga/$relative"
  done < <(find "$ROOT/Sources/Assets/SVGA" -type f ! -name '.DS_Store' ! -name 'Contents.json' -print0)
fi

echo "staged CDN assets under $OUTPUT_ROOT"
find "$OUTPUT_ROOT" -type f ! -name 'asset-manifest.json' -print | sort
