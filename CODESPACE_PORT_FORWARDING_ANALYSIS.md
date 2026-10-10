# Codespaces Port Forwarding Analysis

## Overview

This document analyzes the Codespaces port forwarding behavior for the Hermes WebUI service,
explaining why the forwarded port was flaky on startup and what was done to make it more robust
after removing the Traefik reverse proxy from the architecture.

## Architecture (No Traefik — Direct to WebUI)

```
Codespace user (browser)
    |  (Codespaces port forwarding / VS Code tunnel)
    v
Host VM (devcontainer, --network=host)
    |  (port 8787, WebUI running directly in the devcontainer)
    v
Hermes WebUI (port 8787, running directly in the devcontainer)
    |  (finalize_port_public.py makes 8787 public via Tunnels API + gh CLI)
    v
VS Code Tunnel proxy (public URL)
```

- **Port 8787**: Hermes WebUI Python server (runs directly in the devcontainer).
  This is the port we make public on Codespaces.

### What was removed

Previously, the architecture used a Traefik reverse proxy as an intermediary:

```
Codespace user (browser)
    |  (Codespaces port forwarding / VS Code tunnel)
    v
Host VM (devcontainer, --network=host)
    |  (Docker published port -p 8780:8780)
    v
Docker container: traefik:v3.7.13 (port 8780)
    |  (proxies via host.docker.internal:8787)
    v
Hermes WebUI (port 8787, running directly in the devcontainer)
```

Traefik added unnecessary complexity:
- A Docker container running on the host VM's Docker daemon
- A Docker named volume for config persistence
- A landing-page server on port 8081 (served as a 502–504 fallback by Traefik middleware)
- An extra hop and health-check layer that could race with Codespace startup

The no-Traefik architecture points all port-forwarding logic directly at the WebUI service,
simplifying the stack and eliminating the proxy layer's readiness race conditions.

## The Problem: Automatic Port Forwarding vs. Explicit Forwarding

### Automatic Port Forwarding (Codespaces behavior)

When a Codespace starts, the Codespaces port scanner detects listening ports on the host VM and
automatically registers them as **private** forwarded ports in the VS Code tunnel.

Key characteristics:

- Triggered by the Codespaces post-start lifecycle, not by devcontainer.json
- Only detects ports that are listening on the host VM network namespace at scan time
- Registers ports as **private** by default (only the workspace user can access)
- Timing is non-deterministic — the scan happens at an undefined point relative to
  `postStartCommand` execution

### Explicit Port Forwarding (our post_start_command)

The `post_start_command` script at `/opt/devcontainers/post_start_commands/hermes-webui`:

1. Sources the `.hermes-webui.env` file for API keys and configuration
2. Starts the WebUI on port 8787 via `ctl.sh start`
3. Calls `finalize_port_public.py 8787` which:
   - Polls the WebUI `/health` endpoint until `status == "ok"` (max 120s)
   - Uses the Tunnels Management API to register port 8787
   - Toggles port visibility (private→public) via gh CLI + Tunnels API
   - Verifies the public endpoint returns HTTP 200
   - Retries the entire cycle for up to 5 minutes

### Why They Conflict

The two approaches can race:

1. **Codespaces auto-detects port 8787** (the WebUI) and registers it as private. This
   happens at an unknown time relative to our script.

2. **Our script registers port 8787** as public. This happens after the WebUI health check
   passes (up to 120 seconds).

3. **The Codespace URL that Codespaces auto-generates** for the user points to the
   auto-detected port 8787.

### The Race Condition Timeline

```
T=0:   Codespace container starts
T+0.1: postStartCommand begins executing
T+0.5: WebUI process starts (listening on 8787)
T+1:   Codespaces port scanner may detect 8787 (auto-registration as private)
T+1.1: Codespaces tunnel proxy returns auth-page HTML (5068 bytes) for paths it doesn't route
T+5-30: WebUI becomes ready, /health returns status=ok
T+5-30: finalize_port_public.py registers 8787 as public (Tunnels API + gh CLI)
T+user: User opens the Codespace URL for port 8787
```

If the user opens the URL before `finalize_port_public.py` completes the visibility toggle,
they may see 404 or auth-page HTML (5068 bytes) because the port is still private and the
Codespace tunnel proxy intercepts private-port requests.

## Root Cause: Codespaces Auto-Detects Port 8787

Through live testing, we discovered that the 404/auth-page issue is NOT from a proxy
being unready — it's from the **Codespaces tunnel proxy** returning its own response for
**private** ports.

### What happens:

1. Codespaces auto-detects port 8787 (WebUI listening) and registers it as **private**
2. The Codespace UI may auto-open port 8787 (private) when the user clicks "Open in Browser"
3. The Codespaces tunnel proxy for **private ports** intercepts certain request paths
   and serves its own response — for paths like `/health`, `/api/`, `/static/`, it returns
   the same HTML page (5068 bytes). This is the Codespace tunnel's auth interception, not
   the WebUI itself.
4. When the tunnel proxy can't route properly (e.g., during startup, or for paths it
   doesn't expect), it returns **404 with an empty body** from
   `X-Served-By: tunnels-prod-rel-usw3-v3-cluster`

### Evidence from testing (with Traefik, port 8780 public):

```
Port 8780 (public - Traefik):
  /: 200 (len=2675) - Hermes login page ✓
  /health: 200 (len=285) - JSON health response ✓
  /api/: HTTP 401 - proper auth challenge ✓

Port 8787 (private - WebUI direct):
  /: 200 (len=5068) - Codespace tunnel auth page ✗
  /health: 200 (len=5068) - Codespace tunnel auth page ✗
  /api/: 200 (len=5068) - Codespace tunnel auth page ✗
```

The 5068-byte responses on port 8787 are from the Codespace tunnel proxy's
authentication layer, not from the Hermes WebUI.

## Fixes Applied

### Fix 1: No Traefik — Direct to WebUI on Port 8787

Removed the Traefik reverse proxy entirely. The WebUI runs directly in the devcontainer
on port 8787. `finalize_port_public.py` targets port 8787 directly.

This eliminates:
- The Docker container lifecycle for Traefik
- The named-volume config persistence dance
- The landing-page server on port 8081
- The Traefik→WebUI health-check race condition

### Fix 2: `finalize_port_public.py` makes port 8787 public (Primary Fix)

The `finalize_port_public.py` script (adapted from the 61-branch approach) makes port 8787
public via the Tunnels Management API. The key insight from the analysis:

- **Codespaces auto-detects port 8787 and registers it as private**
- The script's visibility toggle (private→public) **forces the tunnel proxy to tear down
  and recreate the forwarding path**, fixing the 404/auth-page issue

**No `forwardPorts` in `devcontainer.json`:** When Docker published ports are used in a
`--network=host` devcontainer, `forwardPorts` should NOT be set — it creates conflicting
tunnel entries. Instead, let Codespaces auto-detect the port, then use the Tunnels API + gh CLI
visibility toggle to make it public.

### Fix 3: Force Codespace tunnel port visibility refresh (CRITICAL)

The `finalize_port_public.py` script registers the port via the VS Code
Tunnels Management API (PUT), then uses the `gh CLI` visibility toggle
(private→public). The order matters:

1. **gh CLI first** — goes through the Codespace connection layer, which properly
   signals the tunnel proxy to re-establish its forwarding path
2. **Tunnels API second** — ensures the access control entries are set correctly

The entire register+toggle+verify cycle is retried for up to 5 minutes,
ensuring the endpoint becomes accessible even when the initial tunnel
proxy entry is stale.

The `gh CLI` creates a port forwarder that establishes a WebSocket connection to the
tunnel relay endpoint — this physical connection is what makes the public URL
reachable. The Tunnels API PUT alone only manages the Tunnels API layer, NOT the
port forwarding layer, which is why both are needed.

## Key Findings from API Investigation

The `gh codespace ports visibility` command uses the **VS Code Tunnels Management API**
(`tunnels.api.visualstudio.com`), not the GitHub REST API. The visibility toggle works
by updating access control entries on the port via `PUT /api/v1/tunnels/{tunnelId}/ports/{port}`,
which forces the tunnel proxy to tear down and recreate the forwarding path.

### Two-layer port registration

The Codespaces port system has two layers:
- **Tunnels API**: Manages the tunnel object and port access control entries (PUT)
- **Codespace port forwarding service**: Manages the Codespace API `ports` array
- The `gh CLI` visibility toggle goes through both layers (Tunnels API + port forwarding)
- The Tunnels API PUT alone only manages the Tunnels API layer, NOT the port forwarding layer

### The tunnel proxy relay is the key

The `gh CLI`'s `NewPortForwarder` creates a WebSocket connection to the tunnel relay endpoint.
This host connection establishes the forwarding path from the public URL to the codespace's
local port. The Tunnels API PUT does NOT create this connection — only the `gh CLI` (or VS Code
server) does.

### User-scoped endpoint works for any Available codespace

The endpoint `GET /user/codespaces/{name}?internal=true&refresh=true` returns tunnel connection
properties (`tunnelId`, `serviceUri`, `managePortsAccessToken`) for ANY Available codespace —
not just the active session. The earlier 404 errors were from the **repo-scoped** endpoint
(`/repos/{owner}/{repo}/codespaces/{name}`) which returns 404 for user-owned codespaces.

## Testing Methodology

To verify the fix:

1. Commit changes to a feature branch
2. Push to GitHub
3. Create a new Codespace from the feature branch
4. Examine the ports published by the new Codespace via:
   ```bash
   gh codespace ports --codespace "$CODESPACE_NAME"
   ```
5. Verify port 8787 is registered and publicly accessible
6. Verify no 404/auth-page errors on initial load

## Test Results

### No-Traefik Architecture Test

Created a new codespace from the no-Traefik branch:
- No `forwardPorts` in devcontainer.json
- WebUI starts directly on port 8787
- `finalize_port_public.py 8787` runs after health check

```
Ports:
  8787: public  https://<codespace>-8787.app.github.dev

Stability test (10 requests, 3s apart):
  All 10 requests: HTTP 200, status=ok
  0 failures
```

### Port Visibility Investigation

```
Before finalize_port_public.py completes:
  Port 8787: private  (auto-detected by Codespaces)
  Public URL: returns 404 or 5068-byte auth-page HTML

After finalize_port_public.py completes (retry loop):
  Port 8787: public
  Public URL: returns 200 with proper WebUI responses
```

## Reference

- [Forwarding ports in your codespace - GitHub Docs](https://docs.github.com/en/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace)
- [Tunnels Management API](https://learn.microsoft.com/en-us/api/tunnels/tunnels-createport)
- [GitHub CLI codespace port commands](https://cli.github.com/manual/gh_codespace_ports)
