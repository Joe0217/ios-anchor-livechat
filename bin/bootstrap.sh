#!/usr/bin/env bash
# Create missing local xcconfig files from tracked redacted templates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--check" ]; then
  missing=0
  for name in Dev Dev-Archive Test Prod; do
    if [ ! -f "Config/Config-${name}.xcconfig" ]; then
      echo "missing: Config/Config-${name}.xcconfig"
      missing=1
    fi
  done
  exit "$missing"
fi

for name in Dev Dev-Archive Test Prod; do
  target="Config/Config-${name}.xcconfig"
  template="${target}.example"
  if [ ! -f "$target" ]; then
    cp "$template" "$target"
    echo "created: $target"
  fi
done

cat <<'EOF'

Fill every __REQUIRED__ value using the approved credential channel before building.
Then close Xcode and run ./bin/regen.sh.
EOF
