# Codespace WebUI Port Publishing Debugging

## Problem

Startup/restart of a Codespace does not make the Hermes WebUI port (8787) publicly accessible. The
port either fails to register for Codespace port forwarding, or the visibility change to `public`
fails.

## Root Causes Found

### 1. `UID: readonly variable` in `.hermes-webui.env` (FIXED)

The `.hermes-webui.env` sourced `/workspaces/.codespaces/shared/.env` using `set -a; . file`. The
`.env` file contains `UID=1000`, which is a readonly bash builtin. Under `set -euo pipefail` in the
`postStartCommand`, this aborts the entire script before `ctl.sh start` runs.

**Fix**: Moved the selective env parsing directly into `post_start_command`. A `while IFS='=' read`
loop skips readonly/conflicting variables (`UID`, `USER`, `HOME`, `PWD`, `LOGNAME`, `CODESPACES`,
`SHELL`, `_`) and only exports the needed secrets.

### 2. `CODESPACE_NAME` not set in container env (FIXED)

On fresh Codespaces, `CODESPACE_NAME` is only in `/workspaces/.codespaces/shared/.env`, NOT set as a
container environment variable. The `postStartCommand` checked `if [ -z "${CODESPACE_NAME:-}" ]` and
exited early ("Not running in a Codespace"), skipping the `gh codespace ports visibility` call
entirely.

**Fix**: Added fallback to read `CODESPACE_NAME` from `/workspaces/.codespaces/shared/.env`.

### 3. `gh auth login --with-token` pipe terminates the postStartCommand (FIXED)

Piping a token to `gh auth login --with-token` caused the SSH/stdio session to close prematurely,
terminating the script before the port visibility command ran.

**Fix**: Use `export GH_TOKEN="${token}"` instead of `gh auth login --with-token`. The `gh CLI`
automatically uses `GH_TOKEN` for authentication.

### 4. PostStartCommand false-claim bug (FIXED)

The original script printed "Port 8787 is now publicly accessible" unconditionally, even when the
`gh codespace ports visibility` command failed.

**Fix**: Made the success message conditional on verifying the port is actually `public` via
`gh codespace ports`. Clear error diagnostics on failure.

### 5. Health check too weak (FIXED)

The original script used `ctl.sh status | grep 'Health:.*ok'` which only checks that the accept loop
is running, not that system resources are available.

**Fix**: Replaced with `/api/system/health` endpoint polling for BOTH `status: "ok"` AND
`available: true` (confirms CPU/memory/disk metrics are accessible). Added auth login flow (POST
`/api/auth/login` → extract `hermes_session` cookie → use for `/api/system/health` requests).

### 6. `forwardPorts` does NOT register port 8787 (ROOT CAUSE — FIXED via Tunnels API)

This is the core issue. `forwardPorts: [8787]` in `devcontainer.json` does NOT cause the Codespace's
VS Code Tunnel to register port 8787 as a forwarded port. On Codespaces created with pre-built
Docker images, the forwardPorts directive is silently ignored for the Codespace's port-forwarding
tunnel.

**Evidence**:

- `gh codespace ports` returns `[]` (empty) on freshly created Codespaces
- The Tunnels API (`GET /tunnels/{tunnelId}`) shows only auto-detected ports (2222 for SSH,
  16634-16636 for VS Code/Jupyter) — port 8787 is never auto-detected
- The webui IS running and listening on `0.0.0.0:8787` inside the container
- The old Codespace (`stunning-zebra`, created Aug 9 before the hermes-webui partial) has port 8787
  registered — `forwardPorts` worked there

**Fix**: The `post_start_command` now falls back to the VS Code Tunnels Management API when
`gh codespace ports visibility` fails (port not registered). The flow is:

1. Try `gh codespace ports visibility 8787:public` (works if port is pre-registered)
1. If that fails, query `GET /user/codespaces/{name}?internal=true&refresh=true` to retrieve tunnel
   connection properties (tunnelId, managePortsAccessToken, serviceUri)
1. Use `PUT {serviceUri}/tunnels/{tunnelId}/ports/8787` with `accessControl` set to `Anonymous` +
   `connect` scope to create a publicly-accessible port on the tunnel
1. Verify via the portForwardingUris in the API response

This approach uses two different APIs:

- **GitHub REST API** (`/user/codespaces/{name}`) — needs `?internal=true&refresh=true` query params
- **VS Code Tunnels Management API** (`{serviceUri}tunnels/{tunnelId}/ports/{port}`) — uses the
  `managePortsAccessToken` JWT from the Codespace connection info

## Files Changed (on branch `fix/webui-port-public-accessibility`)

| File                              | Change                                                                                                                                                                                                       |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `hermes-webui/post_start_command` | Rewritten: selective env parsing (UID fix), `/api/system/health` health check (status+available+auth), GH_TOKEN auth, two-stage port visibility (gh CLI → Tunnels API fallback), conditional success message |
| `.hermes-webui.env`               | Fixed `UID` readonly error via selective var parsing; exports for `GITHUB_TOKEN` and `CODESPACE_NAME`                                                                                                        |
| `.devcontainer/devcontainer.json` | Added sshd feature for debugging; kept `forwardPorts: [8787]` as a best-effort hint                                                                                                                          |

## Testing Results

### Test 1: Manual verification on `port-test-5x5vjqxx4qqh7x9r` Codespace

1. ✅ WebUI health check passes: `status: ok, available: true` (CPU, memory, disk metrics)
1. ✅ Port 8787 not registered by `forwardPorts` (confirmed via Tunnels API)
1. ✅ Tunnels API `PUT /ports/8787` with Anonymous+connect access control → created port
1. ✅ `gh codespace ports visibility 8787:public` succeeded after port was registered
1. ✅ `curl https://port-test-5x5vjqxx4qqh7x9r-8787.app.github.dev/health` returns
   `{"status":"ok",...}` — publicly accessible

### Test 2: Fresh Codespace on `port-final-test-qp6vjqpppgrf4x6v` (from branch)

1. ✅ **postStartCommand status: SUCCEEDED** (no manual intervention needed)
1. ✅ `gh codespace ports` shows port 8787 as `public`
1. ✅ `browseUrl: https://port-final-test-qp6vjqpppgrf4x6v-8787.app.github.dev`
1. ✅ `curl https://port-final-test-qp6vjqpppgrf4x6v-8787.app.github.dev/health` returns
   `{"status": "ok", "server_started_at": ..., "uptime_seconds": 14.3, ...}`
1. ✅ WebUI is publicly accessible from the internet

## Remaining

- `do_HEAD` fix for upstream `server.py` (HEAD requests return 501 → ERR_INVALID_RESPONSE). A patch
  script exists (`hermes-webui/scripts/patch_server_do_head.py`) but is deferred per user
  instruction. The webui works with GET requests; HEAD only affects browser pre-flight checks which
  fall back to GET after 501.
