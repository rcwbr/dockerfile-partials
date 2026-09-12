# Cleanup Plan: Minimize Traefik Config

## Goal

Create a new branch `cleanup/minimize-traefik-config` to minimize the diff before
merging. Apply cleanup changes from `fix/webui-port-public-accessibility` to `main`.

## Architecture

- WebUI: port 8787 (devcontainer process via `ctl.sh start`)
- Traefik proxy: port 8780 (separate container, `traefik:v3.7.13`)
- Landing page: port 8081 (Python `http.server` background process in devcontainer)
- Port 8780 made public via Tunnels Management API (no `forwardPorts`)

## Changes

### 1. Simplify `.hermes-webui.env` — DONE

Removed the `while IFS='=' read` loop for parsing shared `.env`. Direct
`source /workspaces/.codespaces/shared/.env` with `set +e` guard for UID error.

### 2. Remove sshd feature — DONE

Removed `ghcr.io/devcontainers/features/sshd:1` from `.devcontainer/devcontainer.json`. (SSH not
needed for proxy testing via GH CLI.)

### 3. Remove `forwardPorts` — DONE

Removed from `.devcontainer/devcontainer.json`. Rely on Tunnels API via `finalize_port_public.py`.

### 4. Replace `docker rm -f` — DONE

Using `docker rm -f traefik-proxy` followed by `docker run` (named volume approach).

### 5. Source `.env` directly — DONE

Replaced `grep` parsing with `source /workspaces/.codespaces/shared/.env`.

### 6. Extract port publishing + health polling to Python — DONE

Created `hermes-webui/scripts/finalize_port_public.py`. Handles:
1. Polling `/health` until WebUI returns status == "ok" (max 120 seconds)
2. Making port 8780 publicly accessible via the Tunnels Management API

### 7. Restore `static/index.html`, remove `landing.html` — DONE

### 8. Use named volume + base64 echo for Traefik config — DONE

Config files baked into `/opt/devcontainers/` image are invisible to Docker at
runtime. Solution: write config files into a Docker named volume using `docker exec`
+ base64 echo, then mount the named volume into the Traefik container.

Key finding: `/tmp/` is NOT shared between devcontainer and Docker daemon. Named
volumes are managed by Docker and always accessible.

## TODO List

- [x] 1. Create branch
- [x] 2. Simplify `.hermes-webui.env` (items 1, 5)
- [x] 3. Create `finalize_port_public.py` (items 6, rename from `ensure_port_public.py`)
- [x] 4. Rewrite `post_start_command` (items 3, 4, 6)
- [x] 5. Fix `webui.yml` service names and priorities
- [x] 6. Remove `forwardPorts` from `devcontainer.json` (item 3)
- [x] 7. Restore `static/index.html`, remove `landing.html`
- [x] 8. Remove sshd feature (item 2)
- [x] 9. Use named volume + base64 echo for Traefik config
- [x] 10. Test — port 8780 public, `/health` returns `{"status":"ok"}`
- [x] 11. Open bug issue #61

## Test Results

Tested on `test-final-qp6vjqpp7r9c4q76` Codespace (fresh build with `devcontainer.json` changed):

- ✅ SSH works (sshd temporarily re-added for testing)
- ✅ `finalize_port_public.py` baked into image via Dockerfile `COPY`
- ✅ `postStartCommand` completed with exit code 0
- ✅ Hermes WebUI started (PID 251, bound to 0.0.0.0:8787)
- ✅ Landing page server on port 8081
- ✅ Named volume `traefik-config-data` created and populated via base64 echo
- ✅ Traefik container started from `traefik:v3.7.13` with config from named volume
- ✅ Health polling succeeded (`"status":"ok"`)
- ✅ Port 8780 registered and made public via Tunnels API
- ✅ External URL returns `{"status": "ok"}`: `https://<codespace>-8780.app.github.dev/health`

## Deviations

1. **Named volume + base64 echo for Traefik config**: Docker daemon on Codespace host
   VM cannot see files in the devcontainer's `/opt/devcontainers/` overlay filesystem.
   Writing config files into a Docker named volume via `docker exec` + base64, then
   mounting the volume into Traefik, avoids all filesystem isolation issues.

2. **Landing page**: Python `http.server` on port 8081 (Traefik errors middleware redirects to this when WebUI is down).

3. **Health endpoint**: Using `/health` (public) instead of `/api/system/health` (requires auth).

4. **Env file sourcing**: `source /workspaces/.codespaces/shared/.env` causes
   `UID: readonly variable` error; handled by `set +e`/`set -e` in `.hermes-webui.env`.

5. **`finalize_port_public.py`**: Renamed from `ensure_port_public.py` to reflect its expanded role (health polling + port publishing). Added `COPY` line to Dockerfile so the script is baked into the image.
