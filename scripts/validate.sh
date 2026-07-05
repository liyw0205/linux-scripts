#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT_LINT="${STRICT_LINT:-0}"

if [[ "${1:-}" == "--strict" ]]; then
  STRICT_LINT=1
fi

mapfile -t scripts < <(
  find "$ROOT_DIR" -maxdepth 2 -type f -name '*.sh' \
    ! -path "${ROOT_DIR}/.git/*" \
    | sort
)

status=0
optional_status=0

echo "== bash syntax =="
for script in "${scripts[@]}"; do
  rel="${script#${ROOT_DIR}/}"
  echo "bash -n ${rel}"
  bash -n "$script" || status=1
done

echo
echo "== optional lint =="
if command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck"
  shellcheck -x "${scripts[@]}" || optional_status=1
else
  echo "shellcheck not found; skipped"
fi

if command -v shfmt >/dev/null 2>&1; then
  echo "shfmt -d"
  shfmt -d "${scripts[@]}" || optional_status=1
else
  echo "shfmt not found; skipped"
fi

if [[ "$STRICT_LINT" == "1" && "$optional_status" -ne 0 ]]; then
  status=1
fi

exit "$status"
