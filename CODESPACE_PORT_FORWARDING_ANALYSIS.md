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

## Fix 2: Wait for Traefik Readiness

To make the port forwarding more robust, we added a Traefik readiness wait loop in the
`post_start_command` script. This ensures Traefik is fully operational before
`finalize_port_public.py` attempts to mark port 8780 as public.

The fix adds a polling loop after Traefik starts that:

1. Checks `http://127.0.0.1:8780/health` up to 30 times (60 seconds total)
1. Blocks further script execution until Traefik responds successfully
1. Logs progress so it's visible in the Codespace startup output

This eliminates the race between Traefik being started (Docker container up) and Traefik being ready
to proxy requests (dynamic config loaded, health checks passing).

## Other Mitigation Strategies

### 1. Add `forwardPorts` to devcontainer.json

Declaring ports explicitly in devcontainer.json bypasses auto-detection:

```json
{
  "forwardPorts": [
    8780,
    8787
  ]
}
```

This ensures both ports are registered at container creation time, not discovered later by the
agent. However, auto-detected ports are still private by default; visibility must be changed via
`gh CLI` or the Tunnels API.

### 2. Set Port Visibility Immediately

Call `gh codespace ports visibility 8780:public` immediately after Traefik starts, rather than
waiting for the WebUI health check:

```bash
gh codespace ports visibility 8780:public --codespace "$CODESPACE_NAME" 2>/dev/null || true
```

### 3. Increase Landing Page Refresh Interval

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
