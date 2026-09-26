# Codespaces Port Forwarding Analysis

## Overview

This document analyzes the Codespaces port forwarding behavior for the Hermes WebUI service,
explaining why the forwarded port is flaky on startup and what was done to make it more robust.

## Architecture

```
Codespace user (browser)
    |  (Codespaces port forwarding / VS Code tunnel)
    v
Host VM (devcontainer with --network=host)
    |  (Docker published port -p 8780:8780)
    v
Docker container: traefik:v3.7.13 (port 8780)
    |  (proxies via host.docker.internal:8787)
    v
Hermes WebUI (port 8787, running directly in the devcontainer)
```

- **Port 8787**: Hermes WebUI Python server (runs directly in the devcontainer, not in a Docker
  container)
- **Port 8780**: Traefik reverse proxy (runs in a Docker container on the host, publishes 8780 via
  `-p 8780:8780`)
- **Port 8081**: Landing page server (Python http.server, serves static page while WebUI starts)

## The Problem: Automatic Port Forwarding vs. Explicit Forwarding

### Automatic Port Forwarding (Codespaces behavior)

When a Codespace starts, the devcontainer agent scans for listening ports on the host VM and
automatically registers them as **private** forwarded ports in the VS Code tunnel. This is the
"automatic" path.

Key characteristics:

- Triggered by the Codespaces post-start lifecycle, not by devcontainer.json
- Only detects ports that are listening on the host VM network namespace at scan time
- Registers ports as **private** by default (only the workspace user can access)
- Timing is non-deterministic — the scan happens at an undefined point relative to
  `postStartCommand` execution

### Explicit Port Forwarding (our post_start_command)

The `post_start_command` script at `/opt/devcontainers/post_start_commands/hermes-webui` explicitly:

1. Starts the WebUI on port 8787
1. Starts Traefik in a Docker container (`-p 8780:8780`)
1. Calls `finalize_port_public.py 8780` which uses the Tunnels Management API to register port 8780
   with `Anonymous` + `isGloballyAvailable: true` access

### Why They Conflict

The two approaches can race:

1. **Codespaces auto-detects port 8787** (the WebUI directly) and registers it as private. This
   happens at an unknown time relative to our script.

1. **Our script registers port 8780** (Traefik) as public. This happens after the WebUI health check
   passes (up to 120 seconds).

1. **The Codespace URL that Codespaces auto-generates** for the user points to the auto-detected
   port. If auto-detection catches 8787 first, the user gets
   `https://<codespace>-8787.app.github.dev`. If our script's Traefik registration completes first,
   the user may get `https://<codespace>-8780.app.github.dev`.

1. **404 errors occur when:**

   - The user opens the URL before Traefik is fully ready (health checks still failing, middleware
     redirecting to landing page)
   - The auto-detected port (8787) is registered but the WebUI hasn't fully initialized its routes
     yet
   - Traefik's error middleware (502-504 fallback to landing) conflicts with Codespaces' tunnel
     routing

### The Race Condition Timeline

```
T=0:   Codespace container starts
T+0.1: postStartCommand begins executing
T+0.5: WebUI process starts (listening on 8787)
T+1:   Traefik Docker container starts (publishing 8780)
T+1.1: Codespaces port scanner may detect 8787 (auto-registration as private)
T+1.5: Traefik health checks begin failing (WebUI not ready yet)
T+5-30: WebUI becomes ready, Traefik health checks pass
T+5-30: finalize_port_public.py registers 8780 as public
T+user: User opens the Codespace URL (may be 8787 or 8780 depending on timing)
```

If the user opens the URL between T+1 and T+5, they may hit:

- 8787 direct: 404 (WebUI still booting, no routes available)
- 8780 via Traefik: landing page or 404 (Traefik middleware not fully configured)

## Root Cause: Codespaces Auto-Detects Port 8787

Through live testing on a rebuilt Codespace, we discovered that the 404 is NOT
primarily from Traefik being unready — it's from the **Codespaces tunnel proxy**
returning 404 for port 8787 (the WebUI direct port).

### What happens:

1. Codespaces auto-detects port 8787 (WebUI listening) and registers it as **private**
2. Codespaces also detects port 8780 (Traefik Docker published port) and registers it
3. The Codespace UI may auto-open port 8787 (private) when the user clicks "Open in Browser"
4. The Codespaces tunnel proxy for **private ports** intercepts certain request paths
   and serves its own response — for paths like `/health`, `/api/`, `/static/`, it returns
   the same HTML page (5068 bytes). This is the Codespace tunnel's auth interception, not
   the WebUI itself.
5. When the tunnel proxy can't route properly (e.g., during startup, or for paths it
   doesn't expect), it returns **404 with an empty body** from
   `X-Served-By: tunnels-prod-rel-usw3-v3-cluster`

### Evidence from testing:

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
authentication layer, not from the Hermes WebUI. The tunnel proxy sits between
the user and the private port, and returns 404 when it can't route the request.

## Fix 1: Add `forwardPorts` to devcontainer.json (Primary Fix)

Adding `forwardPorts: [8780]` to `.devcontainer/devcontainer.json` tells Codespaces
to **only** auto-forward port 8780 (Traefik). Port 8787 is no longer auto-detected
or registered, eliminating the competing private port entry that causes 404s.

```json
{
  "forwardPorts": [8780],
  ...
}
```

This is the most impactful single fix — it prevents the Codespace tunnel from
creating a stale/broken entry for port 8787.

## Applied Fixes

### Fix 1: `forwardPorts: [8780]` in devcontainer.json (PRIMARY FIX)

Added `forwardPorts: [8780]` to `.devcontainer/devcontainer.json`. This tells Codespaces
to only auto-forward port 8780 (Traefik), preventing the auto-detection of port 8787
(WebUI direct) which caused 404s through the tunnel proxy's auth interception layer.

### Fix 2: Traefik readiness wait in post_start_command (Support Fix)

Added a Traefik readiness polling loop in the `post_start_command` script that waits
for `http://127.0.0.1:8780/health` to return successfully before calling
`finalize_port_public.py`. This ensures Traefik is fully operational before
port 8780 is marked as public, eliminating race conditions during startup.

### Fix 3: Force Codespace tunnel port visibility refresh (CRITICAL)

Added a visibility toggle loop (`8780:private` → `8780:public`) after
`finalize_port_public.py` in the `post_start_command` script. This forces
the Codespaces tunnel proxy to tear down and recreate the forwarding entry
for port 8780, fixing the `ERR_INVALID_RESPONSE` / 404 that occurs when
the tunnel proxy has a stale forwarding path after a codespace rebuild.

The `finalize_port_public.py` script registers the port via the VS Code
Tunnels API (which returns success even when the tunnel proxy has a broken
entry). The visibility toggle goes through the Codespaces management API,
which actually re-establishes the tunnel proxy's connection to the
Docker-published port.

### Remaining Mitigation Strategies (Recommended)

### 1. Set Port Visibility Immediately

Call `gh codespace ports visibility 8780:public` immediately after Traefik starts, rather than
waiting for the WebUI health check:

```bash
gh codespace ports visibility 8780:public --codespace "$CODESPACE_NAME" 2>/dev/null || true
```

### 2. Increase Landing Page Refresh Interval

The landing page (`index.html`) auto-refreshes every 10 seconds. During startup flapping, this can
cause rapid retry cycles. Increasing to 30 seconds reduces noise:

```html
setTimeout(function() {
    window.location.reload();
}, 30000);
```

## Testing Methodology

To verify the fix:

1. Commit changes to a feature branch
1. Push to GitHub
1. Create a new Codespace from the feature branch
1. Examine the ports published by the new Codespace via:
   ```bash
   gh codespace ports --codespace "$CODESPACE_NAME"
   ```
1. Verify port 8780 is registered and publicly accessible
1. Verify no 404 errors on initial load

## Reference

- [Codespaces port forwarding documentation](https://docs.github.com/en/codespaces/setup-routes/about-port-forwarding-in-codespaces)
- [Tunnels Management API](https://learn.microsoft.com/en-us/api/tunnels/tunnels-createport)
- [GitHub CLI codespace port commands](https://cli.github.com/manual/gh_codespace_ports)
