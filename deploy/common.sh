#!/usr/bin/env bash
set -Eeuo pipefail
export SYSTEMD_PAGER=cat
export SYSTEMD_COLORS=0

DEPLOY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$DEPLOY_DIR/.." && pwd)"
SERVICE=pegaai-tunnel.service
CONFIG_DIR=/etc/pegaai-tunnel
CONFIG="$CONFIG_DIR/nginx.conf"
UNIT=/etc/systemd/system/pegaai-tunnel.service
UI_STEP=0
UI_STEPS=0
UI_TITLE=''
UI_STARTED=$SECONDS

banner() {
    printf '\n========================================================================\n'
    printf '  %s\n' "$1"
    printf '========================================================================\n'
    detail Host "$(uname -n)"
    detail Operator "$(id -un)"
    detail Source "$PROJECT_DIR"
}

detail() { printf '       %-14s %s\n' "$1:" "$2"; }
ok() { printf '  [ OK ] %s\n' "$*"; }
info() { printf '  [INFO] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*" >&2; }
step() {
    UI_STEP=$((UI_STEP + 1))
    UI_TITLE="$*"
    printf '\n[%s/%s] %s\n' "$UI_STEP" "$UI_STEPS" "$UI_TITLE"
}
result() {
    printf '\n------------------------------------------------------------------------\n'
    printf '  RESULT: %s  (elapsed %dm %02ds)\n' "$1" "$(( (SECONDS - UI_STARTED) / 60 ))" "$(( (SECONDS - UI_STARTED) % 60 ))"
    printf '  %s\n' "$2"
    printf '%s\n' '------------------------------------------------------------------------'
}
fail() {
    printf '  [FAIL] %s\n' "$*" >&2
    if [[ "${INSTALL_STARTED:-0}" == 1 ]]; then
        printf '         Installed files may remain. No automatic rollback was attempted.\n' >&2
        printf '         Inspect: sudo journalctl -u %s -n 50 --no-pager\n' "$SERVICE" >&2
    fi
    result FAILED "Stopped during step $UI_STEP/$UI_STEPS: $UI_TITLE." >&2
    exit 1
}
report_failure() {
    printf '\n  [FAIL] Command failed at line %s during %s.\n' "$1" "$UI_TITLE" >&2
    printf '         No automatic rollback was attempted. Inspect the service and installed files.\n' >&2
    result FAILED 'Review the output and system journal before retrying.' >&2
}
require_commands() {
    local command
    for command in "$@"; do
        command -v "$command" >/dev/null || fail "Required command is missing: $command"
    done
}
operator_only() {
    [[ "$(uname -s)" == Linux ]] || fail 'Run this script directly on the approved Ubuntu host.'
    [[ "$(id -u)" != 0 ]] || fail 'Run as an ordinary operator, not sudo bash; the script invokes sudo.'
    require_commands sudo systemctl
    sudo -v
    ok "Running as $(id -un) on $(uname -n); sudo session is ready."
}