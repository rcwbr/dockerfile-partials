# Codespace Proxy Restructure Plan

## Goal

Consolidate the Traefik reverse proxy and landing page into a single hermes-webui Dockerfile
partial, eliminating the custom Caddy sidecar container. The landing page will be a `data:text/html`
URI embedded in the Traefik dynamic config — no separate backend server needed.

## Architecture

| Component     | Port | Process                                                    | Image                        |
| ------------- | ---- | ---------------------------------------------------------- | ---------------------------- |
| Hermes WebUI  | 8787 | `ctl.sh start` (devcontainer process)                      | N/A (devcontainer image)     |
| Traefik proxy | 8780 | `docker compose up` (from postStartCommand)                | `traefik:v3.7.13` (upstream) |
| Landing page  | —    | Embedded as `data:text/html` URI in Traefik dynamic config | No backend needed            |

**Key routing decisions:**

- `forwardPorts` in devcontainer.json: `[8780]` (was `[8787]`)
- `post_start_command` registers port **8780** as public on Codespaces (was 8787)
- Traefik backend: `host.docker.internal:8787` (with
  `extra_hosts: ["host.docker.internal:host-gateway"]`)
- Landing page: `data:text/html,<url-encoded-minimal-html>` as a Traefik `loadBalancer` service
- On 502/503/504 from the webui, Traefik's `errors` middleware redirects to the landing service

## TODO List

### Phase 1: Configuration Changes

- \[x\] 1. DELETE `hermes-webui/traefik/Dockerfile` (custom image no longer needed)
- \[x\] 2. DELETE `hermes-webui/traefik/landing.Dockerfile` (Caddy sidecar removed)
- \[x\] 3. DELETE `hermes-webui/traefik/static/index.html` (HTML is inlined)
- \[x\] 4. CREATE `hermes-webui/traefik/landing.html` (minimal reference HTML for URL-encoding)
- \[x\] 5. REWRITE `hermes-webui/traefik/dynamic/webui.yml` (landing service with `data:` URI,
  backend → `host.docker.internal:8787`)
- \[x\] 6. REWRITE `hermes-webui/traefik/docker-compose.yml` (image: `traefik:v3.7.13`,
  `extra_hosts: ["host.docker.internal:host-gateway"]`)
- \[x\] 7. MODIFY `hermes-webui/Dockerfile` (COPY line already present at line 51)
- \[x\] 8. MODIFY `hermes-webui/post_start_command` (port 8780 registration, `docker compose up` not
  `up --build`, `docker rm -f traefik-proxy` for restart safety)
- \[x\] 9. MODIFY `.devcontainer/devcontainer.json` (`forwardPorts: [8780]`)

### Phase 2: Testing

- \[ \] 10. Test 1: Fresh Codespace — landing page serves when webui is down, proxies when webui is
  up
- \[ \] 11. Test 2: Codespace restart — Traefik container restarts cleanly, port re-registered
- \[ \] 12. Test 3: Codespace stop/start — full lifecycle works
- \[ \] 13. Test 4: Docker image caching — verify COPY placement after RUN layer
- \[ \] 14. Test 5: Landing page fallback — stop webui, verify landing page appears, restart webui,
  verify transition

### Phase 3: Cleanup & Documentation

- \[ \] 15. Delete all test Codespaces
- \[ \] 16. Update this doc with final results

## Deviations

- **Deviation 1 (FOUND, NEEDS APPROVAL)**: `/opt/devcontainers/` is not accessible from
  Docker-in-Docker containers inside the Codespace. The Docker daemon runs on the host VM and has
  its own filesystem view. Files in the devcontainer's `/workspaces/` are visible to Docker
  containers at `/var/lib/docker/codespacemount/workspace/`.

  - **Fix applied**: The `post_start_command` derives the Docker-visible path from
    `CONTAINER_WORKSPACE_FOLDER` and `CODESPACE_NAME` — maps
    `/workspaces/dockerfile-partials/hermes-webui/traefik` →
    `/var/lib/docker/codespacemount/workspace/dockerfile-partials/hermes-webui/traefik`. The
    `docker-compose.yml` uses `${TRAEFIK_CONFIG_DIR}` env var for the bind mount source path.

- **Deviation 2 (FOUND, NEEDS APPROVAL)**: Traefik v3.7.13 does NOT support `data:text/html` URIs as
  `loadBalancer.servers[].url` values. The loadBalancer can only proxy to HTTP/HTTPS backends — it
  cannot serve inline HTML/data-URI content. The `landing-svc` service fails to register, and
  Traefik returns `500 Internal Server Error` instead of the landing page.

  - **Proposed fix**: Revert to a simple `python3 -m http.server 8081` background process started
    from `post_start_command` (the original option A). The Traefik dynamic config will proxy to
    `host.docker.internal:8081` for the landing page fallback on 502/503/504.
