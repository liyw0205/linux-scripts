#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT_LINT="${STRICT_LINT:-0}"

scripts=(
  a2up.sh
  astr.sh
  cf.sh
  mihomo.sh
  mount_webdav.sh
  napcat.sh
  webdav_copyto_relay.sh
)

status=0
optional_status=0

echo "== bash syntax =="
for script in "${scripts[@]}"; do
  path="${ROOT_DIR}/${script}"
  if [[ ! -f "$path" ]]; then
    echo "missing: ${script}"
    status=1
    continue
  fi
  echo "bash -n ${script}"
  bash -n "$path" || status=1
done

echo
echo "== optional lint =="
if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  shellcheck -x "${scripts[@]/#/${ROOT_DIR}/}" || optional_status=1
else
  echo "shellcheck not found; skipped"
fi

if command -v shfmt >/dev/null 2>&1; then
  echo "shfmt -d"
  shfmt -d "${scripts[@]/#/${ROOT_DIR}/}" || optional_status=1
else
  echo "shfmt not found; skipped"
fi

if [[ "$STRICT_LINT" == "1" && "$optional_status" -ne 0 ]]; then
  status=1
fi

exit "$status"
