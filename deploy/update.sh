#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "$#" -eq 0 ]] || fail 'Usage: bash deploy/update.sh'
banner 'Tunnel Proxy - Update'
UI_STEPS=5

update_failure() {
    printf '\n  [FAIL] Update failed at line %s during %s.\n' "$1" "$UI_TITLE" >&2
    if [[ -n "${BACKUP:-}" ]]; then
        printf '         Backup: %s\n' "$BACKUP" >&2
        if [[ "${BACKUP_READY:-0}" != 1 ]]; then
            printf '         Backup may be incomplete; verify its contents before recovery.\n' >&2
        fi
        printf '         Installed files may have changed; no automatic rollback was attempted.\n' >&2
        printf '         See README.md for recovery steps.\n' >&2
    else
        printf '         Installed files were not changed.\n' >&2
    fi
    result FAILED 'Review the output before retrying.' >&2
}
trap 'update_failure "$LINENO"' ERR

compare_file() {
    local comparison_status
    if sudo cmp -s -- "$1" "$2"; then
        return 1
    else
        comparison_status=$?
        [[ "$comparison_status" == 1 ]] || fail "Could not compare $1 with $2."
        return 0
    fi
}

show_diff() {
    local diff_status
    if sudo diff -u -- "$1" "$2"; then
        return 0
    else
        diff_status=$?
        [[ "$diff_status" == 1 ]] || fail "Could not show differences for $1."
    fi
}

step 'Preflight checks'
operator_only
require_commands sudo systemctl nginx cmp diff mktemp cp date
[[ -f "$PROJECT_DIR/nginx.conf" && -f "$PROJECT_DIR/tunnel-proxy.service" ]] || fail 'Source configuration or service unit is missing.'
actual_unit="$(sudo systemctl show "$SERVICE" --property=FragmentPath --value --no-pager)"
[[ "$actual_unit" == "$UNIT" ]] || fail "Unexpected service unit: ${actual_unit:-not installed}."
sudo systemctl is-active --quiet "$SERVICE" || fail "Service $SERVICE is not active; inspect it before updating."
sudo test -f "$CONFIG" && ! sudo test -L "$CONFIG" || fail "Installed configuration is missing or is a symlink: $CONFIG"
sudo test -f "$UNIT" && ! sudo test -L "$UNIT" || fail "Installed service unit is missing or is a symlink: $UNIT"
ok 'Expected installation is present and the service is active.'

step 'Review changes'
config_changed=0
unit_changed=0
if compare_file "$CONFIG" "$PROJECT_DIR/nginx.conf"; then
    config_changed=1
    info 'NGINX configuration differs (installed -> source):'
    show_diff "$CONFIG" "$PROJECT_DIR/nginx.conf"
fi
if compare_file "$UNIT" "$PROJECT_DIR/tunnel-proxy.service"; then
    unit_changed=1
    info 'Service unit differs (installed -> source):'
    show_diff "$UNIT" "$PROJECT_DIR/tunnel-proxy.service"
fi
if ((config_changed == 0 && unit_changed == 0)); then
    result SUCCESS 'Installed files already match the source; no changes made.'
    exit 0
fi
warn 'The source files will replace the installed versions shown above.'
warn 'Review listener, TLS, access-control and unit changes carefully.'
if ((unit_changed)); then
    warn 'A unit change restarts the service and may interrupt active requests.'
fi
read -r -p '  Type APPLY to continue: ' confirmation || fail 'Update cancelled; no changes were applied.'
[[ "$confirmation" == APPLY ]] || fail 'Update cancelled; no changes were applied.'

step 'Validate source configuration'
sudo /usr/sbin/nginx -p /run/tunnel-proxy/ -c "$PROJECT_DIR/nginx.conf" -t
ok 'NGINX configuration test passed.'

step 'Back up and install changes'
BACKUP_ROOT=/var/backups/tunnel-proxy
sudo install -d -o root -g root -m 700 "$BACKUP_ROOT"
BACKUP="$(sudo mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%d-%H%M%S)-XXXXXXXX")"
sudo cp -a -- "$CONFIG" "$BACKUP/nginx.conf"
sudo cp -a -- "$UNIT" "$BACKUP/tunnel-proxy.service"
BACKUP_READY=1
ok 'Backup created before replacing installed files.'
detail Backup "$BACKUP"
if ((config_changed)); then
    sudo cp -- "$PROJECT_DIR/nginx.conf" "$CONFIG"
fi
if ((unit_changed)); then
    sudo cp -- "$PROJECT_DIR/tunnel-proxy.service" "$UNIT"
fi
ok 'Changed files installed.'

step 'Apply changes'
if ((unit_changed)); then
    sudo systemctl daemon-reload
    sudo systemctl restart "$SERVICE"
    ok 'Systemd reloaded and the service restarted.'
else
    sudo systemctl reload "$SERVICE"
    ok 'NGINX reload requested.'
fi
sudo systemctl is-active --quiet "$SERVICE"
result SUCCESS 'Update installed; verify the changed behavior.'
detail Backup "$BACKUP"
detail Status 'bash deploy/status.sh'
info 'A successful reload request alone does not verify the new route or upstream access.'