# Task: Remove Traefik, Point Port Forwarding Directly to Hermes WebUI

## Goal

Start a new branch from `main` in `rcwbr/dockerfile-partials` that eliminates the
Traefik reverse proxy from the hermes-webui partial and routes all Codespaces
port-forwarding logic directly to the Hermes WebUI service (port 8787). The
`finalize_port_public.py` script — inspired by the sophisticated version on
`61-webui-isnt-reliably-accessible-over-the-forwarded-port-on-codespace-launch`
— retains its proven retry logic but targets port 8787 instead of 8780.

## Architecture (after change)

```
Codespace user (browser)
    |  (Codespaces port forwarding / VS Code tunnel)
    v
Host VM (devcontainer, --network=host)
    |  (port 8787 directly)
    v
Hermes WebUI (port 8787, running directly in the devcontainer)
    |  (finalize_port_public.py makes 8787 public via Tunnels API + gh CLI)
    v
VS Code Tunnel proxy (public URL)
```

- **Port 8787**: Hermes WebUI Python server (runs directly in the devcontainer)
- **Port 8081**: Landing page server — REMOVED (no Traefik to proxy to it)
- **Port 8780**: Traefik reverse proxy — REMOVED entirely

## Meta-tasks

- **Keep docs in sync**: When code changes, update `README.md`, `CODESPACE_PORT_FORWARDING_ANALYSIS.md`,
  and this `TASK.md` to match. No drift between inline snippets and on-disk files.
- **Refocus on the task**: The core objective is removing Traefik and pointing
  all config/logic directly to the hermes-webui service. Every change should be
  evaluated against this.
- **Capture key learnings and progress**: Use the "Progress Log" and "Key Learnings"
  sections below to record findings.

## Changes Made

### 1. `hermes-webui/scripts/finalize_port_public.py`
- Changed default port from 8780 → 8787
- Adopted the 61-branch logic: Tunnels API PUT + gh CLI visibility toggle
  (gh-CLI-first ordering) + 5-minute retry loop with fresh tunnel-props re-fetch
- Updated docstring to reflect direct-to-WebUI targeting (no Traefik)

### 2. `hermes-webui/post_start_command`
- Removed Traefik container startup, Docker named-volume config dance, Traefik
  readiness poll loop, and landing-page server on port 8081
- Simplified to: start WebUI via `ctl.sh start`, wait for health, call
  `finalize_port_public.py 8787`

### 3. `hermes-webui/Dockerfile`
- Removed `COPY hermes-webui/traefik /opt/devcontainers/hermes-webui/traefik`

### 4. `hermes-webui/traefik/` directory
- Deleted entirely (`traefik.yml`, `dynamic/webui.yml`, `static/index.html`)

### 5. `CODESPACE_PORT_FORWARDING_ANALYSIS.md`
- Updated architecture diagram and analysis to reflect no-Traefik design

### 6. `README.md`
- Updated hermes-webui section: port 8787, no Traefik references

## Progress Log

| Step | Status | Details |
|------|--------|---------|
| Branch created from main | ✅ | `fix/remove-traefik-direct-webui-port-forwarding` |
| finalize_port_public.py updated | ⬜ | Port 8787, 61-branch logic |
| post_start_command rewritten | ⬜ | Removed Traefik, landing page, simplified |
| Dockerfile updated | ⬜ | Removed traefik COPY |
| traefik/ directory deleted | ⬜ | |
| Docs updated | ⬜ | Analysis doc + README |
| Branch pushed | ⬜ | |
| Codespace created for testing | ⬜ | |
| Port availability verified | ⬜ | |

## Key Learnings

_(to be filled in as work progresses)_

## Remaining Issues / Open Questions

_(to be filled in as work progresses)_
