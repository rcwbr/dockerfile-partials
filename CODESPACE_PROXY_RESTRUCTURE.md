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
  `up --build`, `docker rm -f traefik-proxy`, Python landing page server, `nohup`/`disown` for
  process persistence, Docker-visible path derivation)
- \[x\] 8. MODIFY `.devcontainer/devcontainer.json` (`forwardPorts: [8780]`)

### Phase 2: Testing

- \[x\] 9. Test 1: Fresh Codespace — landing page serves when webui is down, proxies when webui is
  up
  - ✅ Port 8780 public, Traefik running, Python server running, webui health returns ok
  - ✅ When webui stopped: Traefik returns landing page on `/` (502 → redirect to
    `host.docker.internal:8081`)
  - ✅ When webui started: Traefik proxies to webui, `/health` returns `{"status": "ok"}`
- \[x\] 10. Test 2: Codespace restart — Traefik container restarts cleanly, port re-registered
- \[x\] 11. Test 3: Codespace stop/start — full lifecycle works
- \[ \] 12. Test 4: Docker image caching — verify COPY placement after RUN layer
- \[x\] 13. Test 5: Landing page fallback — stop webui, verify landing page appears, restart webui,
  verify transition

### Phase 3: Cleanup & Documentation

- \[ \] 14. Delete all test Codespaces
- \[x\] 15. Update this doc with final results

## Deviations

- **Deviation 1 (FOUND, APPROVED)**: `/opt/devcontainers/` is not accessible from Docker-in-Docker
  containers inside the Codespace. The Docker daemon runs on the host VM with its own filesystem
  view. Files in the devcontainer's `/workspaces/` are visible to Docker containers at
  `/var/lib/docker/codespacemount/workspace/`.

  - **Fix applied**: The `post_start_command` derives the Docker-visible path from
    `CONTAINER_WORKSPACE_FOLDER` + `CODESPACE_NAME` — maps
    `/workspaces/dockerfile-partials/hermes-webui/traefik` →
    `/var/lib/docker/codespacemount/workspace/dockerfile-partials/hermes-webui/traefik`. The
    `docker-compose.yml` uses `${TRAEFIK_CONFIG_DIR}` env var for bind mount sources.

- **Deviation 2 (FOUND, APPROVED)**: Traefik v3.7.13 does NOT support `data:text/html` URIs as
  `loadBalancer.servers[].url` values. The loadBalancer can only proxy to HTTP/HTTPS backends — it
  cannot serve inline HTML/data-URI content. The `landing-svc` service fails to register with error:
  `the service "landing@file" does not exist`.

  - **Fix applied**: Reverted to a simple `python3 -m http.server 8081` background process started
    from `post_start_command` (using `nohup` + `disown` for persistence). The Traefik dynamic config
    proxies to `host.docker.internal:8081` for the landing page fallback.

## Final Configuration

### Files

- `hermes-webui/traefik/docker-compose.yml` — uses `traefik:v3.7.13` image,
  `extra_hosts: ["host.docker.internal:host-gateway"]`, `${TRAEFIK_CONFIG_DIR}` for bind mounts
- `hermes-webui/traefik/dynamic/webui.yml` — router/service config with landing page fallback
- `hermes-webui/traefik/static/index.html` — landing page HTML (served by Python http.server)
- `hermes-webui/traefik/traefik.yml` — static Traefik config (entryPoints, providers, logging)
- `hermes-webui/traefik/Dockerfile` — **DELETED** (using upstream `traefik:v3.7.13`)
- `hermes-webui/traefik/landing.Dockerfile` — **DELETED** (Caddy removed)
- `hermes-webui/post_start_command` — starts webui, Python landing server, Traefik container, waits
  for health, registers port 8780
- `.devcontainer/devcontainer.json` — `forwardPorts: [8780]`
