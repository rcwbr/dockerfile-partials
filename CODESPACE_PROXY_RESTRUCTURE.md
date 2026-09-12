# Codespace Proxy Restructure Plan

## Goal

Consolidate the Traefik reverse proxy and landing page into a single hermes-webui Dockerfile
partial, eliminating the custom Caddy sidecar container. The landing page is served by a lightweight
Python `http.server` background process started from `post_start_command` — no separate Docker
container.

## Architecture

| Component     | Port | Process                                                       | Image                        |
| ------------- | ---- | ------------------------------------------------------------- | ---------------------------- |
| Hermes WebUI  | 8787 | `ctl.sh start` (devcontainer process)                         | N/A (devcontainer image)     |
| Landing page  | 8081 | `python3 -m http.server` (background process in devcontainer) | N/A (devcontainer process)   |
| Traefik proxy | 8780 | `docker compose up` (from postStartCommand)                   | `traefik:v3.7.13` (upstream) |

**Key routing decisions:**

- `forwardPorts` in devcontainer.json: `[8780]` (was `[8787]`)
- `post_start_command` registers port **8780** as public on Codespaces (was 8787)
- Traefik backend: `host.docker.internal:8787` (with
  `extra_hosts: ["host.docker.internal:host-gateway"]`)
- Landing page backend: `host.docker.internal:8081` (Python http.server in the devcontainer)
- On 502/503/504 from the webui, Traefik's `errors` middleware redirects to the landing service

**Path mapping in Codespaces:**

- Devcontainer processes see config at `/opt/devcontainers/hermes-webui/traefik/` (baked into image)
- Docker containers (Traefik) see config at
  `/var/lib/docker/codespacemount/workspace/dockerfile-partials/hermes-webui/traefik/`
- `post_start_command` exports `TRAEFIK_CONFIG_DIR` with the Docker-visible path
- `docker-compose.yml` uses `${TRAEFIK_CONFIG_DIR}` for bind mount sources

## TODO List

### Phase 1: Configuration Changes

- \[x\] 1. DELETE `hermes-webui/traefik/Dockerfile` (custom image no longer needed)
- \[x\] 2. DELETE `hermes-webui/traefik/landing.Dockerfile` (Caddy sidecar removed)
- \[x\] 3. RESTORE `hermes-webui/traefik/static/index.html` (landing page HTML, served by Python)
- \[x\] 4. REWRITE `hermes-webui/traefik/dynamic/webui.yml` (landing service →
  `host.docker.internal:8081`, webui backend → `host.docker.internal:8787`)
- \[x\] 5. REWRITE `hermes-webui/traefik/docker-compose.yml` (image: `traefik:v3.7.13`,
  `extra_hosts`, `${TRAEFIK_CONFIG_DIR}` for bind mounts, no `build`)
- \[x\] 6. MODIFY `hermes-webui/Dockerfile` (COPY line already present at line 51)
- \[x\] 7. MODIFY `hermes-webui/post_start_command` (port 8780 registration, `docker compose up` not
  `up --build`, `docker rm -f traefik-proxy` for restart safety, Python landing page server with
  `nohup`/`disown`, Docker-visible path derivation for `TRAEFIK_CONFIG_DIR`)
- \[x\] 8. MODIFY `.devcontainer/devcontainer.json` (`forwardPorts: [8780]`)

### Phase 2: Testing

- \[x\] 9. Test 1: Fresh Codespace (`proxy-v2-7pw769pp74rfrvjj`)
  - ✅ Port 8780 public via `forwardPorts` (no Tunnels API fallback needed)
  - ✅ Traefik v3.7.13 running, Python http.server on 8081 running
  - ✅ WebUI health check passed: `status: ok, available: true`
  - ✅ `curl /health` returns webui health JSON `{"status": "ok", ...}` (proxied through Traefik)
  - ✅ `curl /api/system/health` returns `{"error":"Authentication required"}` (auth working)
  - ✅ When webui stopped: `curl /` returns landing page HTML (502 → errors middleware → landing
    service)
  - ✅ When webui restarted (after ~15s health check interval): `curl /health` returns webui health
    JSON
  - ✅ `postStartCommand` exited with code 0
- \[x\] 10. Test 2: Codespace rebuild — Traefik `docker rm -f` cleanup works, container restarts
- \[x\] 11. Test 3: Process persistence — `nohup` + `disown` keeps Python server alive across shell
  sessions
- \[x\] 12. Test 4: Docker image caching — COPY line at Dockerfile line 51 (after RUN layer, before
  final COPY) — unchanged from original, cache-friendly
- \[x\] 13. Test 5: Landing page fallback verified (webui stop → landing page, webui restart →
  proxy)

### Phase 3: Cleanup & Documentation

- \[x\] 14. Delete test Codespaces (`proxy-v2-7pw769pp74rfrvjj` deleted after validation)
- \[x\] 15. Final commit and push

## Deviations

- **Deviation 1 (FOUND, APPROVED)**: `/opt/devcontainers/` is not accessible from Docker-in-Docker
  containers inside the Codespace. The Docker daemon runs on the host VM with its own filesystem
  view. Files in the devcontainer's `/workspaces/` are visible to Docker containers at
  `/var/lib/docker/codespacemount/workspace/`.

  - **Fix applied**: The `post_start_command` derives the Docker-visible path from
    `CONTAINER_WORKSPACE_FOLDER` + `CODESPACE_NAME` — maps
    `/workspaces/dockerfile-partials/hermes-webui/traefik` →
    `/var/lib/docker/codespacemount/workspace/dockerfile-partials/hermes-webui/traefik`. The
    `docker-compose.yml` uses `${TRAEFIK_CONFIG_DIR}` env var for bind mount sources. This was
    tested and confirmed working on `proxy-v2` Codespace.

- **Deviation 2 (FOUND, APPROVED)**: Traefik v3.7.13 does NOT support `data:text/html` URIs as
  `loadBalancer.servers[].url` values. The loadBalancer can only proxy to HTTP/HTTPS backends — it
  cannot serve inline HTML/data-URI content. The `landing-svc` service fails to register with error:
  `the service "landing@file" does not exist`.

  - **Fix applied**: Reverted to a simple
    `python3 -m http.server 8081 --directory /opt/devcontainers/hermes-webui/traefik/static`
    background process started from `post_start_command` (using `nohup` + `disown` for persistence).
    The Traefik dynamic config proxies to `host.docker.internal:8081` for the landing page fallback.

## Final Configuration

### Files

- `hermes-webui/traefik/docker-compose.yml` — uses `traefik:v3.7.13` image,
  `extra_hosts: ["host.docker.internal:host-gateway"]`, `${TRAEFIK_CONFIG_DIR}` for bind mounts, no
  `build` section
- `hermes-webui/traefik/dynamic/webui.yml` — router/service config with landing page fallback
  (502/503/504 → landing service on `host.docker.internal:8081`)
- `hermes-webui/traefik/static/index.html` — landing page HTML (served by Python http.server)
- `hermes-webui/traefik/traefik.yml` — static Traefik config (entryPoints, providers, logging)
- `hermes-webui/traefik/Dockerfile` — **DELETED** (using upstream `traefik:v3.7.13`)
- `hermes-webui/traefik/landing.Dockerfile` — **DELETED** (Caddy removed)
- `hermes-webui/post_start_command` — starts webui, Python landing server, Traefik container, waits
  for health, registers port 8780
- `.devcontainer/devcontainer.json` — `forwardPorts: [8780]`
