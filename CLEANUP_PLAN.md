# Cleanup Plan: Minimize Traefik Config

## Goal

Create a new branch `cleanup/minimize-traefik-config` to minimize the diff before merging. Apply
cleanup changes from `fix/webui-port-public-accessibility` to `main`.

## Architecture

- WebUI: port 8787 (devcontainer process via `ctl.sh start`)
- Traefik proxy: port 8780 (separate container, `traefik:v3.7.13`)
- Landing page: port 8081 (Python `http.server` background process in devcontainer)
- Port 8780 made public via Tunnels Management API (no `forwardPorts`)

## Test Strategy

- Create fresh Codespace from `cleanup/minimize-traefik-config` branch
- Verify port 8780 is public via `gh codespace ports`
- Verify `https://<codespace>-8780.app.github.dev/health` returns `{"status":"ok"}`
- Verify Traefik container runs without errors

## Changes

### 1. Simplify `.hermes-webui.env` — DONE

Removed the `while IFS='=' read` loop for parsing shared `.env`. Direct
`source /workspaces/.codespaces/shared/.env` with `set +e` guard for UID error.

### 2. Remove sshd feature — DONE

Removed `ghcr.io/devcontainers/features/sshd:1` from `.devcontainer/devcontainer.json`. (SSH not
needed for proxy testing via GH CLI.)

### 3. Remove `forwardPorts` — DONE

Removed from `.devcontainer/devcontainer.json`. Rely on Tunnels API via `ensure_port_public.py`.

### 4. Replace docker rm -f — DONE

Using `docker rm -f traefik-proxy` followed by `docker run` (image-baking approach).

### 5. Source `.env` directly — DONE

Replaced `grep` parsing with `source /workspaces/.codespaces/shared/.env`.

### 6. Extract port publishing to Python — DONE

Created `hermes-webui/scripts/finalize_port_public.py`. Handles full Tunnels API flow + /health polling.

### 7. Remove `hermes-webui/traefik/Dockerfile` — DONE (earlier)

Traefik uses `traefik:v3.7.13` image directly.

### 8. Inline Traefik config — PARTIAL

Static config (`traefik.yml`) baked into image layer via `docker commit`. Dynamic config
(`webui.yml`) must remain a file (Traefik file provider). No volume mounts needed — config lives in
the image.

## TODO List

- \[x\] 1. Create branch
- \[x\] 2. Simplify `.hermes-webui.env` (items 1, 5)
- [x] 3. Create `finalize_port_public.py` (item 6)
- \[x\] 4. Rewrite `post_start_command` (items 3, 4, 6)
- \[x\] 5. Fix `webui.yml` service names and priorities
- \[x\] 6. Remove `forwardPorts` from `devcontainer.json` (item 3)
- \[x\] 7. Restore `static/index.html`, remove `landing.html`
- \[x\] 8. Remove sshd feature (item 2)
- \[x\] 9. Use image-baking for Traefik config (no volume mounts)
- [x] 10. Test — port 8780 public, `/health` returns `{"status":"ok"}` (via `test-sshd` Codespace)
- [x] 11. Open bug issue #61

## Deviations

1. **Image-baking for Traefik config**: Docker daemon on Codespace host VM cannot see
   `/opt/devcontainers/` from devcontainer container, and `/workspaces/` bind mounts don't propagate
   writes. Solution: bake config into image layer via `docker run` (temp container) +
   `docker cp`-like base64 write + `docker commit` + `docker run` committed image.
1. **Landing page**: Python `http.server` on port 8081 (Traefik errors middleware redirects to this
   when WebUI is down).
1. **Health endpoint**: Using `/health` (public) instead of `/api/system/health` (requires auth).
1. **Env file sourcing**: `source /workspaces/.codespaces/shared/.env` causes
   `UID: readonly variable` error; wrapped in `set +e`/`set -e` in `.hermes-webui.env`.
