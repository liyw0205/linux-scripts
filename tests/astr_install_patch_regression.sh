#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    echo "[FAIL] $*" >&2
    exit 1
}

write_fake_bins() {
    local bin="$1"

    cat > "$bin/apt-get" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
    chmod +x "$bin/apt-get"

    cat > "$bin/python3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    venv="$3"
    mkdir -p "$venv/bin"
    cat > "$venv/bin/python" <<'PYEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
    printf '%s\n' "$*" >> "${FAKE_ASTR_LOG:?}"
    if [[ "${FAKE_ASTR_REQUIRE_ACTIVATED:-0}" == "1" && "${FAKE_ASTR_ACTIVATED:-0}" != "1" ]]; then
        exit 9
    fi
    if [[ "${FAKE_ASTR_PIP_FAIL:-0}" == "1" ]]; then
        exit 1
    fi
    touch "$(dirname "$0")/../pip-installed"
    exit 0
fi
exit 0
PYEOF
    chmod +x "$venv/bin/python"
    printf '#!/usr/bin/env sh\nexit 0\n' > "$venv/bin/pip"
    chmod +x "$venv/bin/pip"
    cat > "$venv/bin/activate" <<ACTEOF
VIRTUAL_ENV="$venv"
export VIRTUAL_ENV
PATH="\$VIRTUAL_ENV/bin:\$PATH"
export PATH
export FAKE_ASTR_ACTIVATED=1
ACTEOF
    exit 0
fi
exit 1
EOF
    chmod +x "$bin/python3"
}

create_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git init -q "$repo"
    git -C "$repo" config user.email test@example.invalid
    git -C "$repo" config user.name "Test User"
    printf '%s\n' "old-requirement" > "$repo/requirements.txt"
    git -C "$repo" add requirements.txt
    git -C "$repo" commit -q -m "initial"
    git -C "$repo" branch -M main
}

advance_repo() {
    local repo="$1"
    printf '%s\n' "new-requirement" > "$repo/requirements.txt"
    git -C "$repo" add requirements.txt
    git -C "$repo" commit -q -m "update requirements"
}

assert_no_astr_temp() {
    local dir="$1"
    if find "$dir" -maxdepth 1 \( -name '.app.clone.*' -o -name '.venv.venv.*' -o -name '.venv.requirements.*' -o -name '.venv.backup.*' \) -print -quit | grep -q .; then
        fail "temporary AstrBot artifact leaked in $dir"
    fi
}

assert_venv_activates() {
    local venv="$1"
    local python_path pip_path

    (
        # shellcheck disable=SC1090
        source "$venv/bin/activate"
        [[ "${VIRTUAL_ENV:-}" == "$venv" ]] || exit 20
        python_path="$(command -v python || true)"
        pip_path="$(command -v pip || true)"
        [[ "$python_path" == "$venv/bin/python" ]] || exit 21
        [[ "$pip_path" == "$venv/bin/pip" ]] || exit 22
    ) || fail "venv activation should target final venv path: $venv"
}

set_astr_paths() {
    local name="$1"
    APP_DIR="$TMP_DIR/$name/app"
    VENV_DIR="$TMP_DIR/$name/venv"
    APP_PID_FILE="${APP_DIR}/astr.pid"
    SUPERVISOR_PID_FILE="${APP_DIR}/astr-supervisor.pid"
    STOP_FILE="${APP_DIR}/astr.stop"
    LOG_FILE="${APP_DIR}/astr.log"
    PYTHON="${VENV_DIR}/bin/python"
    mkdir -p "$TMP_DIR/$name"
}

mkdir -p "$TMP_DIR/bin"
write_fake_bins "$TMP_DIR/bin"
export PATH="$TMP_DIR/bin:$PATH"
export FAKE_ASTR_LOG="$TMP_DIR/astr-pip.log"
: > "$FAKE_ASTR_LOG"

# shellcheck disable=SC1090
. "$ROOT_DIR/astr.sh"

repo="$TMP_DIR/repo"
create_repo "$repo"

set_astr_paths clone-fail
if ASTR_REPO_URL="$TMP_DIR/missing-repo" install_astr >/dev/null 2>/dev/null; then
    fail "install should fail when git clone fails"
fi
[[ ! -e "$APP_DIR" ]] || fail "clone failure should not publish app"
[[ ! -e "$VENV_DIR" ]] || fail "clone failure should not publish venv"
assert_no_astr_temp "$TMP_DIR/clone-fail"

set_astr_paths pip-fail
if FAKE_ASTR_PIP_FAIL=1 ASTR_REPO_URL="$repo" install_astr >/dev/null 2>/dev/null; then
    fail "install should fail when staging pip install fails"
fi
[[ ! -e "$APP_DIR" ]] || fail "pip failure should not publish app"
[[ ! -e "$VENV_DIR" ]] || fail "pip failure should not publish venv"
assert_no_astr_temp "$TMP_DIR/pip-fail"

set_astr_paths existing-app
git clone -q "$repo" "$APP_DIR"
mkdir -p "$VENV_DIR"
ASTR_REPO_URL="$repo" install_astr >/dev/null
[[ -d "$APP_DIR/.git" ]] || fail "existing app repo should be preserved"
[[ -x "$VENV_DIR/bin/python" ]] || fail "missing venv should be created through staging"
assert_venv_activates "$VENV_DIR"
assert_no_astr_temp "$TMP_DIR/existing-app"

set_astr_paths repair-broken
git clone -q "$repo" "$APP_DIR"
bad_venv="$TMP_DIR/repair-broken/.venv.venv.bad"
python3 -m venv "$bad_venv"
mv "$bad_venv" "$VENV_DIR"
if venv_is_usable "$VENV_DIR"; then
    fail "moved venv should be detected as unusable"
fi
ASTR_REPO_URL="$repo" install_astr >/dev/null
assert_venv_activates "$VENV_DIR"
assert_no_astr_temp "$TMP_DIR/repair-broken"

conflict_repo="$TMP_DIR/conflict-repo"
create_repo "$conflict_repo"
set_astr_paths untracked-conflict
ASTR_REPO_URL="$conflict_repo" install_astr >/dev/null
conflict_head="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "local artifact" > "$APP_DIR/local-only.txt"
printf '%s\n' "remote tracked" > "$conflict_repo/local-only.txt"
git -C "$conflict_repo" add local-only.txt
git -C "$conflict_repo" commit -q -m "add conflicting tracked file"
if update_astr >/dev/null 2>/dev/null; then
    fail "update should refuse to overwrite untracked local files"
fi
[[ "$(git -C "$APP_DIR" rev-parse HEAD)" == "$conflict_head" ]] || fail "untracked conflict should preserve old HEAD"
grep -qx "local artifact" "$APP_DIR/local-only.txt" || fail "untracked conflict should preserve local file"

set_astr_paths success
ASTR_REPO_URL="$repo" install_astr >/dev/null
[[ -d "$APP_DIR/.git" ]] || fail "install should publish app repo"
[[ -x "$VENV_DIR/bin/python" ]] || fail "install should publish venv python"
[[ -f "$VENV_DIR/pip-installed" ]] || fail "install should run pip in staging venv"
assert_venv_activates "$VENV_DIR"

old_head="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "old venv" > "$VENV_DIR/marker"
advance_repo "$repo"
if FAKE_ASTR_PIP_FAIL=1 patch_astr >/dev/null 2>/dev/null; then
    fail "patch should fail when staging pip install fails"
fi
[[ "$(git -C "$APP_DIR" rev-parse HEAD)" == "$old_head" ]] || fail "failed patch should preserve old HEAD"
grep -qx "old venv" "$VENV_DIR/marker" || fail "failed patch should preserve old venv"
assert_no_astr_temp "$TMP_DIR/success"

printf '%s\n' "local tracked edit" > "$APP_DIR/requirements.txt"
printf '%s\n' "local untracked artifact" > "$APP_DIR/local-artifact.txt"
FAKE_ASTR_REQUIRE_ACTIVATED=1 update_astr >/dev/null
grep -qx "new-requirement" "$APP_DIR/requirements.txt" || fail "update should git pull latest requirements"
grep -qx "old venv" "$VENV_DIR/marker" || fail "update should reuse existing venv"
grep -qx "local untracked artifact" "$APP_DIR/local-artifact.txt" || fail "update should preserve untracked local files"
grep -q -- "-r $APP_DIR/requirements.txt" "$FAKE_ASTR_LOG" || fail "update should install requirements from app dir"
assert_venv_activates "$VENV_DIR"

printf '%s\n' "newer-requirement" > "$repo/requirements.txt"
git -C "$repo" add requirements.txt
git -C "$repo" commit -q -m "second update"
FAKE_ASTR_REQUIRE_ACTIVATED=1 patch_astr >/dev/null
grep -qx "newer-requirement" "$APP_DIR/requirements.txt" || fail "patch should fast-forward app code"
assert_venv_activates "$VENV_DIR"

update_head="$(git -C "$APP_DIR" rev-parse HEAD)"
printf '%s\n' "latest-requirement" > "$repo/requirements.txt"
git -C "$repo" add requirements.txt
git -C "$repo" commit -q -m "third update"
if FAKE_ASTR_REQUIRE_ACTIVATED=1 FAKE_ASTR_PIP_FAIL=1 update_astr >/dev/null 2>/dev/null; then
    fail "update should fail when dependency install fails"
fi
[[ "$(git -C "$APP_DIR" rev-parse HEAD)" == "$update_head" ]] || fail "failed update should roll back git HEAD"
grep -qx "newer-requirement" "$APP_DIR/requirements.txt" || fail "failed update should restore previous code"
assert_venv_activates "$VENV_DIR"

echo "ok - astr install update and patch preserve artifacts"
