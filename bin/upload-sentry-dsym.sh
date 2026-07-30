#!/usr/bin/env bash
# Upload an archived dSYM bundle to Sentry. Credentials are supplied only by CI or
# the approved release environment; never store them in this repository.

set -euo pipefail

: "${SENTRY_AUTH_TOKEN:?SENTRY_AUTH_TOKEN must be set by CI or the release environment}"
: "${SENTRY_ORG:?SENTRY_ORG must be set by CI or the release environment}"
: "${SENTRY_PROJECT:?SENTRY_PROJECT must be set by CI or the release environment}"

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "sentry-cli is required to upload dSYMs" >&2
  exit 1
fi

dsym_path="${1:-}"
if [[ -z "$dsym_path" || ! -d "$dsym_path" ]]; then
  echo "usage: $0 <path-to-dSYM-or-dSYM-directory>" >&2
  exit 64
fi

sentry-cli debug-files upload --include-sources "$dsym_path"
