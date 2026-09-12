# Codespace Proxy Restructure Plan

## Goal

Consolidate the Traefik reverse proxy and landing page into a single hermes-webui Dockerfile
partial, eliminating the custom Caddy sidecar container. The landing page will be served by a simple
Python `http.server` background process, with Traefik's `errors` middleware proxying to it on
502/503/504.

## Architecture

| Component     | Port | Process                                                       | Image                        |
| ------------- | ---- | ------------------------------------------------------------- | ---------------------------- |
| Hermes WebUI  | 8787 | `ctl.sh start` (devcontainer process)                         | N/A (devcontainer image)     |
| Traefik proxy | 8780 | `docker compose up` (from postStartCommand)                   | `traefik:v3.7.13` (upstream) |
| Landing page  | 8081 | `python3 -m http.server` (background process in devcontainer) | N/A (Python stdlib)          |

**Key routing decisions:**

- `forwardPorts` in devcontainer.json: `[8780]` (was `[8787]`)
- `post_start_command` registers port **8780** as public on Codespaces (both via
  `gh codespace ports visibility` and Tunnels API fallback)
- Traefik backend: `host.docker.internal:8787` (with
  `extra_hosts: ["host.docker.internal:host-gateway"]`)
- Landing page backend: `host.docker.internal:8081` (Python http.server background process)
- On 502/503/504 from the webui, Traefik's `errors` middleware serves the landing page from the
  Python server

## TODO List

### Phase 1: Configuration Changes

- \[x\] 1. DELETE `hermes-webui/traefik/Dockerfile` (custom image no longer needed)
- \[x\] 2. DELETE `hermes-webui/traefik/landing.Dockerfile` (Caddy sidecar removed)
- \[x\] 3. DELETE `hermes-webui/traefik/static/index.html` (was for Caddy; will be recreated as
  landing page)
- \[x\] 4. CREATE `hermes-webui/traefik/static/index.html` (landing page HTML)
- \[x\] 5. UPDATE `hermes-webui/traefik/dynamic/webui.yml` (landing-svc →
  `host.docker.internal:8081`, hermes-webui-svc → `host.docker.internal:8787`)
- \[x\] 6. UPDATE `hermes-webui/traefik/docker-compose.yml` (image: `traefik:v3.7.13`,
  `extra_hosts`, `TRAEFIK_CONFIG_DIR` env var for Docker-visible path)
- \[x\] 7. MODIFY `hermes-webui/Dockerfile` (COPY line already present; no changes needed)
- \[x\] 8. UPDATE `hermes-webui/post_start_command` (start Python landing server, port 8780
  registration, path derivation for Codespace Docker)
- \[x\] 9. UPDATE `.devcontainer/devcontainer.json` (`forwardPorts: [8780]`)

### Phase 2: Testing

- \[ \] 10. Test 1: Fresh Codespace — landing page serves when webui is down, proxies when webui is
  up
- \[ \] 11. Test 2: Codespace restart — Traefik + Python server restart cleanly, port re-registered
- \[ \] 12. Test 3: Codespace stop/start — full lifecycle works
- \[ \] 13. Test 4: Docker image caching — verify COPY placement after RUN layer
- \[ \] 14. Test 5: Landing page fallback — stop webui, verify landing page appears, restart webui,
  verify transition

### Phase 3: Cleanup & Documentation

- \[ \] 15. Delete all test Codespaces
- \[ \] 16. Update this doc with final results

## Deviations

- **Deviation 1 (FOUND, APPROVED)**: `/opt/devcontainers/` is not accessible from Docker-in-Docker
  containers inside the Codespace. The Docker daemon runs on the host VM with its own filesystem
  view. Files in the devcontainer's `/workspaces/` are visible to Docker containers at
  `/var/lib/docker/codespacemount/workspace/`.

  - **Fix applied**: The `post_start_command` derives the Docker-visible path from
    `CONTAINER_WORKSPACE_FOLDER` + `CODESPACE_NAME` — maps
    `/workspaces/dockerfile-partials/hermes-webui/traefik` to
    `/var/lib/docker/codespacemount/workspace/dockerfile-partials/hermes-webui/traefik`. The
    `docker-compose.yml` uses `${TRAEFIK_CONFIG_DIR}` env var for the bind mount source path.

- **Deviation 2 (FOUND, APPROVED)**: Traefik v3.7.13 does NOT support `data:text/html` URIs as
  `loadBalancer.servers[].url` values. The loadBalancer can only proxy to HTTP/HTTPS backends — it
  cannot serve inline HTML/data-URI content. Confirmed by Traefik official documentation: "The error
  page itself is not hosted by Traefik."

  - **Fix applied**: Revert to a simple
    `python3 -m http.server 8081 --directory /opt/devcontainers/hermes-webui/traefik/static`
    background process started from `post_start_command`. The Traefik dynamic config (`webui.yml`)
    proxies to `host.docker.internal:8081` for the landing page fallback on 502/503/504 via the
    `errors` middleware.
