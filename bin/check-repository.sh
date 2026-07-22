#!/usr/bin/env bash
# Fast, dependency-free checks for files that must stay safe to share.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required=(README.md AGENTS.md project.yml Podfile Podfile.lock bin/bootstrap.sh bin/regen.sh)
for file in "${required[@]}"; do
  if [ ! -f "$file" ]; then
    echo "error: missing required file: $file" >&2
    exit 1
  fi
done

for name in Dev Dev-Archive Test Prod; do
  template="Config/Config-${name}.xcconfig.example"
  if ! grep -q 'HILY_AGORA_APP_ID = __REQUIRED__' "$template"; then
    echo "error: invalid config template: $template" >&2
    exit 1
  fi
done

if git ls-files --error-unmatch Config/Config-Dev.xcconfig >/dev/null 2>&1; then
  echo "warning: Config/Config-Dev.xcconfig is still tracked; rotate its credentials, then remove it from Git."
fi

non_placeholder_values="$(awk -F= '/^[[:space:]]*HILY_[A-Z_]+/ && $2 !~ /__REQUIRED/ { print FILENAME ":" FNR ":" $0 }' Config/*.xcconfig.example)"
if [ -n "$non_placeholder_values" ]; then
  echo "error: a config template contains a non-placeholder value" >&2
  printf '%s\n' "$non_placeholder_values" >&2
  exit 1
fi

echo "repository hygiene checks passed"
