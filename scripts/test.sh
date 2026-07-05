#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== regression tests =="
if command -v bats >/dev/null 2>&1; then
  echo "bats tests/webdav_copyto_relay.bats"
  bats "$ROOT_DIR/tests/webdav_copyto_relay.bats"
else
  echo "bats not found; using bash fallback"
  bash "$ROOT_DIR/tests/webdav_copyto_relay_regression.sh" all
fi

bash "$ROOT_DIR/tests/cf_local_writes_regression.sh"
bash "$ROOT_DIR/tests/cf_command_regression.sh"
bash "$ROOT_DIR/tests/cf_install_download_regression.sh"
bash "$ROOT_DIR/tests/mihomo_yaml_helpers_regression.sh"
bash "$ROOT_DIR/tests/mihomo_subscription_update_regression.sh"
bash "$ROOT_DIR/tests/mihomo_install_atomic_regression.sh"
bash "$ROOT_DIR/tests/a2up_config_service_regression.sh"
bash "$ROOT_DIR/tests/mount_webdav_regression.sh"
bash "$ROOT_DIR/tests/astr_state_regression.sh"
bash "$ROOT_DIR/tests/astr_install_patch_regression.sh"
bash "$ROOT_DIR/tests/napcat_state_regression.sh"
bash "$ROOT_DIR/tests/napcat_patch_regression.sh"
bash "$ROOT_DIR/tests/napcat_install_regression.sh"
