# PegaAI tunnel

An NGINX reverse proxy for AICC's OpenAI-compatible LLM endpoint. Each client supplies its own AICC API key as a Bearer token; the proxy forwards it without substituting a server key. Model availability and authorization remain controlled by AICC.

| Client request | AICC request |
| --- | --- |
| `/v1/chat/completions` | `/pegaai/v1/chat/completions` |
| `/v1/models` | `/pegaai/v1/models` |
| `/maas/api/v1/model-status/public/models` | `/maas/api/v1/model-status/public/models` |

All paths below `/v1/` and the exact model-status path are forwarded, including query strings. Streaming responses are not buffered. Other paths return 404. The model-status endpoint returns AICC's public listing, which may include non-LLM models and does not guarantee access to each model. The supplied model JSON files are snapshots, not live model lists; this proxy does not serve them. TTS, image, embedding and other separate endpoints are not included.

## Security

The default listener is `127.0.0.1:4714` over HTTP. It is for local testing only and is not reachable by other machines. Do not expose it directly on a network: API keys and prompts would travel in plaintext.

For remote clients, configure HTTPS and restrict access to approved networks as described below, or place the loopback listener behind an existing approved HTTPS reverse proxy. Restrict its direct access so users cannot bypass TLS. The proxy host and its administrators can see API keys and prompts. NGINX access logging is disabled, but error logs or other infrastructure can still contain request details; review log handling and retention. Never log authorization headers or request bodies. This proxy relies on AICC to authenticate each request; it does not authenticate clients independently or enforce per-user quotas. Follow company policy before exposing the service.

The Ubuntu server needs DNS and outbound HTTPS access to `aicc-gateway.pegatroncorp.com`, and its CA trust store must trust the upstream certificate. Upstream certificate verification and SNI are enabled. If your organization intercepts TLS, install its approved CA into the system trust store; do not disable verification.

## Install on Ubuntu

Perform these commands directly on the approved Ubuntu host. Transfer this folder using your company's approved process. The example assumes it is available as `/opt/tunnel-proxy`. Run scripts as an ordinary operator with sudo access, not as root.

```bash
sudo apt update
sudo apt install nginx ca-certificates
cd /opt/tunnel-proxy
bash deploy/install.sh
bash deploy/status.sh
```

The installer validates the source configuration, checks that port 4714 is free, and starts a separate NGINX instance. It refuses to overwrite an existing installation or configuration. It does not install packages, change the existing NGINX configuration, enable remote access, or send an API key to AICC. The final check only verifies that a local request to an unconfigured path returns 404. If installation fails after files have been copied, no automatic rollback occurs; inspect the files and logs before retrying. Check errors with:

```bash
sudo journalctl -u tunnel-proxy.service -n 50 --no-pager
```

## Update an existing installation

Transfer the updated source using your company's approved process, then run as an ordinary operator:

```bash
cd /opt/tunnel-proxy
bash deploy/update.sh
bash deploy/status.sh
```

The update script shows the differences between the installed files and source files. Review them carefully: applying them replaces the changed installed files, including any server-specific TLS, listener, access-control or unit settings. Merge settings you want to keep into the source files before applying. Type `APPLY` to continue; any other response cancels without changing the installation.

The script validates the source NGINX configuration, backs up both installed files under `/var/backups/tunnel-proxy/`, then installs only the changed files. For configuration-only changes, it requests an NGINX reload. If the service unit changes, it runs `systemctl daemon-reload` and restarts the service, which may interrupt active requests. It does not change systemd drop-ins. A successful reload request does not prove that the new configuration was applied or that AICC is reachable; inspect the journal and test the changed behavior.

If an update fails after backup, it does not roll back automatically. Inspect the printed backup directory and the journal. To restore both files when the backup is complete, replace the example path below with the printed backup path:

```bash
BACKUP=/var/backups/tunnel-proxy/REPLACE-WITH-BACKUP-DIRECTORY
sudo ls -l "$BACKUP"
sudo cp -a "$BACKUP/nginx.conf" /etc/tunnel-proxy/nginx.conf
sudo cp -a "$BACKUP/tunnel-proxy.service" /etc/systemd/system/tunnel-proxy.service
sudo systemctl daemon-reload
sudo nginx -p /run/tunnel-proxy/ -c /etc/tunnel-proxy/nginx.conf -t
```

Only if the configuration test succeeds, restart and check the service:

```bash
sudo systemctl restart tunnel-proxy.service
bash deploy/status.sh
```

If the service is stopped, `/run/tunnel-proxy/` may be absent; inspect the journal and restore the service with operator assistance rather than assuming this test succeeded.

## Test locally on Ubuntu

Enter your own AICC API key at the prompt. Do not paste it into commands, chat, source files, or logs.

```bash
read -rsp 'AICC API key: ' AICC_API_KEY
echo
curl --fail-with-body \
  -H "Authorization: Bearer ${AICC_API_KEY}" \
  http://127.0.0.1:4714/v1/models
```

Try a chat request with a model your key is allowed to use:

```bash
curl --fail-with-body \
  -H "Authorization: Bearer ${AICC_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Pega-Chat","messages":[{"role":"user","content":"Hello"}]}' \
  http://127.0.0.1:4714/v1/chat/completions
```

To query the AICC public model status through the tunnel:

```bash
curl --noproxy '*' --fail-with-body \
  -H "Authorization: Bearer ${AICC_API_KEY}" \
  http://127.0.0.1:4714/maas/api/v1/model-status/public/models
unset AICC_API_KEY
```

The key is still visible to privileged processes and may briefly appear in the `curl` process arguments. Run these tests only on a trusted host. A `401` or `403` can be returned by AICC for an invalid key or insufficient model access. The status snapshots do not guarantee that an alias is accepted or currently available.

For an existing installation, apply the model-status `location` block with the update procedure above, preserving any server-specific settings. The first-install script deliberately refuses existing installations.

## Enable HTTPS for remote clients

Obtain an approved hostname, certificate and private key, and confirm the permitted client IP ranges and firewall rules. If an existing HTTPS proxy is already in use, route its `/v1/` requests and the exact `/maas/api/v1/model-status/public/models` path to `http://127.0.0.1:4714` without changing the paths, and disable response buffering for streaming. Preserve the client `Authorization` header and restrict access at that proxy.

Alternatively, edit the `server` block in `/etc/tunnel-proxy/nginx.conf`: replace the `listen 127.0.0.1:4714;` line with the following, substituting your actual paths and approved CIDR. Keep the existing locations unchanged.

```nginx
listen 443 ssl;
server_name your-approved-hostname.example;
ssl_certificate /path/to/your/fullchain.pem;
ssl_certificate_key /path/to/your/private-key.pem;
allow YOUR_APPROVED_CIDR;
deny all;
```

Restrict private-key permissions, allow only approved clients through the firewall, and ensure port 443 is not already in use. If it is, integrate with the existing HTTPS proxy instead of stopping it. Test and restart:

```bash
sudo nginx -p /run/tunnel-proxy/ -c /etc/tunnel-proxy/nginx.conf -t
sudo systemctl restart tunnel-proxy.service
sudo systemctl status tunnel-proxy.service --no-pager
```

Clients can then use `https://your-approved-hostname.example/v1` as their base URL and their own AICC key as the API key. Verify both streaming and non-streaming requests, and test that disallowed networks cannot connect. A valid certificate must match the hostname. Do not disable TLS verification in clients.

## Local regression test

The regression tests are maintained locally and are not included in this repository. They use a mock upstream; real upstream TLS and credentials must be verified separately.
