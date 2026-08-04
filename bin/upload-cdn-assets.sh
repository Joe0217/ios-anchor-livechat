#!/usr/bin/env bash
# Upload a reviewed CDNAssets tree through the same OSS PostObject contract used
# by OssUploadService. Credentials are supplied out-of-band and never persisted.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INPUT_ROOT="$ROOT/CDNAssets"
CREDENTIAL_FILE="${OSS_CREDENTIAL_FILE:-}"
PREFIX="iosAnchor/assets"
VERSION="$(date +%Y%m%d)"
JOBS=4
SAMPLE=0
DRY_RUN=0
VERIFY=1
MANIFEST_PATH=""

usage() {
  cat >&2 <<'EOF'
usage: bin/upload-cdn-assets.sh [options]

Required for a real upload:
  --credential-file <json>  Short-lived /sts/getOssUploadParam response.
  The file is read locally, never copied, logged, or written to the manifest.

Options:
  --input-root <dir>        Staging tree (default: CDNAssets)
  --prefix <path>           Object prefix (default: iosAnchor/assets)
  --version <value>         Version folder (default: YYYYMMDD)
  --jobs <n>                Concurrent upload batch size (default: 4)
  --sample                  Upload one file from each category for testing
  --dry-run                 List selected files and object keys only
  --no-verify               Skip CDN HEAD checks
  --manifest <file>         Output manifest (default: <input-root>/asset-manifest.json)
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --credential-file)
      [[ $# -ge 2 ]] || usage
      CREDENTIAL_FILE="$2"
      shift 2
      ;;
    --input-root)
      [[ $# -ge 2 ]] || usage
      INPUT_ROOT="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || usage
      PREFIX="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || usage
      VERSION="$2"
      shift 2
      ;;
    --jobs)
      [[ $# -ge 2 ]] || usage
      JOBS="$2"
      shift 2
      ;;
    --sample)
      SAMPLE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    --manifest)
      [[ $# -ge 2 ]] || usage
      MANIFEST_PATH="$2"
      shift 2
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

if [[ "$INPUT_ROOT" != /* ]]; then
  INPUT_ROOT="$ROOT/$INPUT_ROOT"
fi
if [[ -z "$MANIFEST_PATH" ]]; then
  MANIFEST_PATH="$INPUT_ROOT/asset-manifest.json"
elif [[ "$MANIFEST_PATH" != /* ]]; then
  MANIFEST_PATH="$ROOT/$MANIFEST_PATH"
fi

[[ -d "$INPUT_ROOT" ]] || { echo "input root does not exist: $INPUT_ROOT" >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "--jobs must be a positive integer" >&2; exit 64; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "shasum is required" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 0 ]]; then
  [[ -n "$CREDENTIAL_FILE" ]] || { echo "--credential-file is required unless --dry-run is used" >&2; exit 64; }
  [[ -f "$CREDENTIAL_FILE" ]] || { echo "credential file does not exist" >&2; exit 1; }
  if [[ "$(stat -f '%Lp' "$CREDENTIAL_FILE" 2>/dev/null || stat -c '%a' "$CREDENTIAL_FILE" 2>/dev/null)" != "600" ]]; then
    echo "warning: credential file permissions are not 600; tighten them before uploading" >&2
  fi
fi

# Keep object keys predictable and reject characters that would need URL escaping.
validate_key() {
  [[ "$1" =~ ^[A-Za-z0-9._@/-]+$ ]] || {
    echo "unsupported path characters in object key: $1" >&2
    return 1
  }
}

mime_for() {
  case "${1##*.}" in
    png|PNG) echo image/png ;;
    jpg|JPG|jpeg|JPEG) echo image/jpeg ;;
    gif|GIF) echo image/gif ;;
    webp|WEBP) echo image/webp ;;
    heic|HEIC) echo image/heic ;;
    svga|SVGA) echo application/octet-stream ;;
    mp4|MP4) echo video/mp4 ;;
    mov|MOV) echo video/quicktime ;;
    *) echo application/octet-stream ;;
  esac
}

FILES=()
for category in common 107 gif svga; do
  category_dir="$INPUT_ROOT/$category"
  [[ -d "$category_dir" ]] || continue
  if [[ "$SAMPLE" -eq 1 ]]; then
    sample_limit=1
    [[ "$category" == "common" ]] && sample_limit=3
    [[ "$category" == "gif" ]] && sample_limit=2
    sample_count=0
    while IFS= read -r sample_file; do
      FILES+=("$sample_file")
      sample_count=$((sample_count + 1))
      [[ "$sample_count" -ge "$sample_limit" ]] && break
    done < <(find "$category_dir" -type f ! -name '.DS_Store' ! -name 'Contents.json' -print)
  else
    while IFS= read -r -d '' file; do FILES+=("$file"); done < <(
      find "$category_dir" -type f ! -name '.DS_Store' ! -name 'Contents.json' -print0
    )
  fi
done

[[ "${#FILES[@]}" -gt 0 ]] || { echo "no uploadable files under $INPUT_ROOT/{common,107,gif,svga}" >&2; exit 1; }

if [[ "$DRY_RUN" -eq 1 ]]; then
  for file in "${FILES[@]}"; do
    relative="${file#"$INPUT_ROOT/"}"
    key="$PREFIX/v$VERSION/$relative"
    validate_key "$key"
    bytes="$(wc -c < "$file" | tr -d '[:space:]')"
    echo "$relative -> $key ($(mime_for "$file"), ${bytes} bytes)"
  done
  echo "dry-run selected ${#FILES[@]} file(s)"
  exit 0
fi

credential_scope="$(jq -c '(.data // .result // .)' "$CREDENTIAL_FILE")"
accessid="$(jq -er '.accessid' <<<"$credential_scope")"
policy="$(jq -er '.policy' <<<"$credential_scope")"
signature="$(jq -er '.signature' <<<"$credential_scope")"
host="$(jq -er '.host' <<<"$credential_scope")"
cdn_url="$(jq -er '.cdnUrl' <<<"$credential_scope")"
expire="$(jq -er '.expire' <<<"$credential_scope")"
for value in "$host" "$cdn_url"; do [[ "$value" == https://* ]] || { echo "OSS host/cdnUrl must use https" >&2; exit 1; }; done
[[ "$expire" =~ ^[0-9]+$ ]] || { echo "OSS credential expire must be an epoch timestamp" >&2; exit 1; }
[[ "$expire" -gt "$(date +%s)" ]] || { echo "OSS credential has expired; request a new one after login" >&2; exit 1; }

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/iosAnchor-cdn.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
result_dir="$work_dir/results"
mkdir -p "$result_dir"

upload_one() {
  local index="$1" file="$2" relative key mime bytes sha url response_file
  relative="${file#"$INPUT_ROOT/"}"
  key="$PREFIX/v$VERSION/$relative"
  validate_key "$key" || return 1
  mime="$(mime_for "$file")"
  bytes="$(wc -c < "$file" | tr -d '[:space:]')"
  sha="$(shasum -a 256 "$file" | awk '{print $1}')"
  response_file="$result_dir/$index.response"

  if curl -fsS --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 180 \
      -X POST "$host" \
      -F "key=$key" \
      -F "policy=$policy" \
      -F "Signature=$signature" \
      -F "OSSAccessKeyId=$accessid" \
      -F 'success_action_status=200' \
      -F "file=@$file;filename=$(basename "$file");type=$mime" \
      >"$response_file" 2>"$response_file.err"; then
    url="${cdn_url%/}/$key"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$index" "$relative" "$url" "$bytes" "$sha" "$mime" >"$result_dir/$index.tsv"
    echo "uploaded $relative -> $url"
  else
    echo "upload failed: $relative (response saved temporarily for diagnostics)" >&2
    return 1
  fi
}

failed=0
running=0
for index in "${!FILES[@]}"; do
  upload_one "$index" "${FILES[$index]}" &
  running=$((running + 1))
  if [[ "$running" -ge "$JOBS" ]]; then
    wait || failed=1
    running=0
  fi
done
if [[ "$running" -gt 0 ]]; then wait || failed=1; fi
[[ "$failed" -eq 0 ]] || { echo "one or more uploads failed" >&2; exit 1; }

manifest_tmp="$work_dir/manifest.jsonl"
: > "$manifest_tmp"
for index in "${!FILES[@]}"; do
  [[ -f "$result_dir/$index.tsv" ]] || continue
  IFS=$'\t' read -r _ relative url bytes sha mime < "$result_dir/$index.tsv"
  category="${relative%%/*}"
  jq -cn --arg local "$relative" --arg category "$category" --arg url "$url" --arg version "$VERSION" \
    --arg sha256 "$sha" --arg mime "$mime" --argjson bytes "$bytes" \
    '{category:$category,localPath:$local,cdnUrl:$url,version:$version,bytes:$bytes,sha256:$sha256,mime:$mime}' >> "$manifest_tmp"
done
jq -s '.' "$manifest_tmp" > "$MANIFEST_PATH"

if [[ "$VERIFY" -eq 1 ]]; then
  while IFS=$'\t' read -r _ _ url _ _ _; do
    curl -fsSI --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 30 "$url" >/dev/null || {
      echo "CDN HEAD failed: $url" >&2
      failed=1
    }
  done < <(cat "$result_dir"/*.tsv 2>/dev/null || true)
  [[ "$failed" -eq 0 ]] || exit 1
fi

echo "uploaded ${#FILES[@]} file(s); manifest: $MANIFEST_PATH"
