#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "$#" -eq 0 ]] || fail 'Usage: bash deploy/status.sh'
banner 'PegaAI Tunnel - Status (read-only)'
UI_STEPS=4
trap 'report_failure "$LINENO"' ERR

step 'Check installation'
operator_only
require_commands nginx ss curl awk grep
actual_unit="$(sudo systemctl show "$SERVICE" --property=FragmentPath --value --no-pager)"
[[ "$actual_unit" == "$UNIT" ]] || fail "Unexpected service unit: ${actual_unit:-not installed}."
sudo test -r "$CONFIG" || fail "Configuration is not readable: $CONFIG"
ok 'Expected service unit and configuration are present.'
detail Unit "$UNIT"
detail Config "$CONFIG"

step 'Check service'
sudo systemctl show "$SERVICE" --no-pager \
    -p ActiveState -p SubState -p MainPID -p NRestarts \
    -p ExecMainStartTimestamp -p ExecMainStatus | awk '{ printf "       %s\n", $0 }'
sudo systemctl is-active --quiet "$SERVICE" || fail "Service $SERVICE is not active."
ok "Service $SERVICE is active."

step 'Validate NGINX configuration'
sudo /usr/sbin/nginx -p /run/pegaai-tunnel/ -c "$CONFIG" -t
ok 'NGINX configuration test passed.'

step 'Check listener'
listen_lines="$(sudo awk '/^[[:space:]]*listen[[:space:]]/ { print }' "$CONFIG")"
if [[ "$listen_lines" =~ ^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:8080\;[[:space:]]*$ ]] && ! sudo grep -Eq '^[[:space:]]*include[[:space:]]' "$CONFIG"; then
    listeners="$(ss -H -ltn '( sport = :8080 )')"
    [[ -n "$listeners" ]] || fail 'No listener found on port 8080.'
    printf '%s\n' "$listeners" | awk '{ printf "       %s\n", $0 }'
    response="$(curl --noproxy '*' --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:8080/not-allowed)"
    [[ "$response" == 404 ]] || fail "Local rejection check returned HTTP $response, expected 404."
    ok 'Local listener responds and rejects an unconfigured path (HTTP 404).'
else
    info 'Listener differs from the default or uses includes; no local HTTP probe was attempted.'
    info 'Verify the configured HTTPS listener and network restrictions separately.'
fi

result SUCCESS 'Installation and service checks passed.'
detail Logs 'sudo journalctl -u pegaai-tunnel.service -n 50 --no-pager'
info 'Upstream TLS, credentials, inference, and remote access were not tested.'