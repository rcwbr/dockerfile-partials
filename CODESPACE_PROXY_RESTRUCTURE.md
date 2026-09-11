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

None yet. Any deviations discovered during implementation will be documented here and require user
approval before proceeding.
