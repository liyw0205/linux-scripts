#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=""

cleanup() {
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

write_fake_bins() {
  local bin="$1"

  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out=""
config=""

if [[ -n "${FAKE_CURL_ARGS_LOG:-}" ]]; then
  printf '%s\n' "$@" > "$FAKE_CURL_ARGS_LOG"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    --config)
      if [[ "${2:-}" == "-" ]]; then
        config="$(cat)"
      else
        config="$(cat "$2")"
      fi
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$out" ]] || exit 2

if [[ -n "${FAKE_CURL_CONFIG_LOG:-}" ]]; then
  printf '%s\n' "$config" > "$FAKE_CURL_CONFIG_LOG"
fi

case "${FAKE_CURL_MODE:-valid}" in
  valid)
    version="${FAKE_SUB_VERSION:-v1}"
    cat > "$out" <<SUB
proxies:
  - name: "${version}"
    type: direct
proxy-groups: []
rules:
  - MATCH,DIRECT
SUB
    ;;
  html)
    {
      printf '<!doctype html><html><body>'
      printf '%80s' "not a subscription"
      printf '</body></html>'
    } > "$out"
    ;;
  small)
    printf 'tiny' > "$out"
    ;;
  fail)
    printf 'partial subscription' > "$out"
    exit 23
    ;;
  *)
    exit 3
    ;;
esac
EOF
  chmod +x "$bin/curl"

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 97
EOF
  chmod +x "$bin/systemctl"
}

reset_mihomo_paths() {
  rm -rf "$TMP_DIR/mihomo"
  MIHOMO_DIR="$TMP_DIR/mihomo"
  CONFIG_FILE="$MIHOMO_DIR/config.yaml"
  SUB_FILE="$MIHOMO_DIR/subscription.yaml"
  SUB_URL_FILE="$MIHOMO_DIR/subscription.url"
  COUNTRY_MMDB="$MIHOMO_DIR/Country.mmdb"
  SOCKS5_GROUP_STATE="$MIHOMO_DIR/socks5_group.conf"
  mkdir -p "$MIHOMO_DIR"
}

assert_no_secret_in_output() {
  local output="$1"
  local secret="$2"
  [[ "$output" != *"$secret"* ]] || fail "command output leaked subscription token"
}

TMP_DIR="$(mktemp -d)"
mkdir -p "$TMP_DIR/bin"
write_fake_bins "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"
export FAKE_CURL_ARGS_LOG="$TMP_DIR/curl.args"
export FAKE_CURL_CONFIG_LOG="$TMP_DIR/curl.config"

# shellcheck disable=SC1090
. "$ROOT_DIR/mihomo.sh"

check_root() {
  return 0
}

test_and_restart() {
  return 0
}

reset_mihomo_paths
secret_token="SECRET_TOKEN_123"
sub_url="https://example.invalid/sub?token=${secret_token}"

output="$(FAKE_CURL_MODE=valid FAKE_SUB_VERSION=v1 import_subscription "$sub_url" 2>&1)"
assert_no_secret_in_output "$output" "$secret_token"
grep -q 'name: "v1"' "$SUB_FILE" || fail "import should publish subscription file"
[[ "$(get_subscription_url)" == "$sub_url" ]] || fail "import should save subscription url"

mode="$(stat -c '%a' "$SUB_URL_FILE" 2>/dev/null || true)"
[[ -z "$mode" || "$mode" == "600" ]] || fail "subscription url file should be mode 600"
! grep -q "$secret_token" "$FAKE_CURL_ARGS_LOG" || fail "subscription url leaked into curl argv"
grep -q "$secret_token" "$FAKE_CURL_CONFIG_LOG" || fail "fake curl did not receive subscription url via config"

status_output="$(show_subscription_status 2>&1)"
assert_no_secret_in_output "$status_output" "$secret_token"
[[ "$status_output" == *"订阅链接：已保存"* ]] || fail "status should report saved subscription url without printing it"

output="$(FAKE_CURL_MODE=valid FAKE_SUB_VERSION=v2 update_subscription 2>&1)"
assert_no_secret_in_output "$output" "$secret_token"
grep -q 'name: "v2"' "$SUB_FILE" || fail "update should refresh subscription file"
[[ "$(get_subscription_url)" == "$sub_url" ]] || fail "update should keep subscription url"

output="$(FAKE_CURL_MODE=valid FAKE_SUB_VERSION=v3 main sub update 2>&1)"
assert_no_secret_in_output "$output" "$secret_token"
grep -q 'name: "v3"' "$SUB_FILE" || fail "sub update dispatch should refresh subscription file"

output="$(FAKE_CURL_MODE=valid FAKE_SUB_VERSION=v4 main update-sub 2>&1)"
assert_no_secret_in_output "$output" "$secret_token"
grep -q 'name: "v4"' "$SUB_FILE" || fail "update-sub alias should refresh subscription file"

rm -f "$SUB_URL_FILE"
if update_subscription >"$TMP_DIR/no-url.out" 2>&1; then
  fail "update should fail when subscription url is missing"
fi
grep -q "未找到已保存的订阅链接" "$TMP_DIR/no-url.out" || fail "missing url message should be Chinese and actionable"

printf '%s\n' "old subscription content that should stay" > "$SUB_FILE"
old_url="https://example.invalid/sub?token=OLD_TOKEN"
new_url="https://example.invalid/sub?token=NEW_TOKEN_SHOULD_NOT_LEAK"
save_subscription_url "$old_url"

if FAKE_CURL_MODE=html import_subscription "$new_url" >"$TMP_DIR/import-html.out" 2>&1; then
  fail "HTML subscription import should fail"
fi
grep -qx "old subscription content that should stay" "$SUB_FILE" || fail "failed import should preserve old subscription"
[[ "$(get_subscription_url)" == "$old_url" ]] || fail "failed import should preserve old subscription url"
assert_no_secret_in_output "$(cat "$TMP_DIR/import-html.out")" "NEW_TOKEN_SHOULD_NOT_LEAK"

if FAKE_CURL_MODE=small update_subscription >"$TMP_DIR/update-small.out" 2>&1; then
  fail "small subscription update should fail"
fi
grep -qx "old subscription content that should stay" "$SUB_FILE" || fail "failed update should preserve old subscription"
[[ "$(get_subscription_url)" == "$old_url" ]] || fail "failed update should preserve old subscription url"
assert_no_secret_in_output "$(cat "$TMP_DIR/update-small.out")" "OLD_TOKEN"

echo "ok - mihomo subscription update"
