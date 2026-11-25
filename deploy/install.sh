#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "$#" -eq 0 ]] || fail 'Usage: bash deploy/install.sh'
banner 'PegaAI Tunnel - First Installation'
UI_STEPS=5
trap 'report_failure "$LINENO"' ERR

step 'Preflight checks'
operator_only
require_commands nginx ss curl awk grep mktemp mkdir rm
[[ -f "$PROJECT_DIR/nginx.conf" ]] || fail "Source configuration is missing: $PROJECT_DIR/nginx.conf"
[[ -f "$PROJECT_DIR/proxy-tunnel.service" ]] || fail "Source service unit is missing: $PROJECT_DIR/proxy-tunnel.service"
sudo test -x /usr/sbin/nginx || fail 'Ubuntu NGINX is not installed at /usr/sbin/nginx.'
sudo test -r /etc/ssl/certs/ca-certificates.crt || fail 'The system CA trust bundle is missing.'
if sudo test -e "$CONFIG_DIR" || sudo test -L "$CONFIG_DIR" || sudo test -e "$UNIT" || sudo test -L "$UNIT"; then
    fail 'Existing installation or configuration detected; no files were changed.'
fi
load_state="$(sudo systemctl show "$SERVICE" --property=LoadState --value --no-pager)"
[[ "$load_state" == not-found ]] || fail "Existing installation detected (systemd load state: $load_state)."
listeners="$(ss -H -ltn '( sport = :4714 )')"
[[ -z "$listeners" ]] || fail 'Port 4714 is already in use; no files were changed.'
listen_lines="$(awk '/^[[:space:]]*listen[[:space:]]/ { print }' "$PROJECT_DIR/nginx.conf")"
[[ "$listen_lines" =~ ^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:4714\;[[:space:]]*$ ]] || fail 'Source configuration must have exactly one 127.0.0.1:4714 listener.'
if grep -Eq '^[[:space:]]*include[[:space:]]' "$PROJECT_DIR/nginx.conf"; then
    fail 'Source configuration includes additional files; review them manually before deployment.'
fi
ok 'Required tools, installation paths, and loopback port are available.'
detail Listener '127.0.0.1:4714 (local HTTP only)'
detail Upstream 'AICC HTTPS; user-provided Bearer key'

step 'Validate source configuration'
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pegaai-nginx-check.XXXXXXXX")"
trap 'rm -rf -- "$CHECK_DIR"' EXIT
mkdir -p "$CHECK_DIR/logs" "$CHECK_DIR/temp"
sudo /usr/sbin/nginx -p "$CHECK_DIR/" -c "$PROJECT_DIR/nginx.conf" -t
ok 'NGINX configuration test passed.'

step 'Install configuration and service'
INSTALL_STARTED=1
sudo install -d -o root -g root -m 755 "$CONFIG_DIR"
sudo install -o root -g root -m 644 "$PROJECT_DIR/nginx.conf" "$CONFIG"
sudo install -o root -g root -m 644 "$PROJECT_DIR/proxy-tunnel.service" "$UNIT"
ok 'Configuration and systemd unit installed.'
detail Config "$CONFIG"
detail Unit "$UNIT"

step 'Start service'
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE"
sudo systemctl is-active --quiet "$SERVICE" || fail "Service $SERVICE is not active; inspect its journal."
ok "Service $SERVICE is enabled and active."

step 'Verify local listener'
response="$(curl --noproxy '*' --silent --show-error --max-time 5 --output /dev/null --write-out '%{http_code}' http://127.0.0.1:4714/not-allowed)"
[[ "$response" == 404 ]] || fail "Local rejection check returned HTTP $response, expected 404."
ok 'Local listener responds and rejects an unconfigured path (HTTP 404).'
info 'No API key or AICC inference request was used in this check.'

result SUCCESS 'Installation is active on localhost only.'
detail Status 'bash deploy/status.sh'
detail Logs 'sudo journalctl -u pegaai-tunnel.service -n 50 --no-pager'
warn 'Remote clients require approved HTTPS and access controls; see README.md.'
warn 'Verify upstream access with your own API key; the local check does not test AICC.'