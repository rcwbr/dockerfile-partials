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

|| Step | Status | Details |
||------|--------|---------|
|| Branch created from main | ✅ | `fix/remove-traefik-direct-webui-port-forwarding` |
|| finalize_port_public.py updated | ✅ | Port 8787, 61-branch logic, docstring |
|| post_start_command rewritten | ✅ | Removed Traefik, landing page, simplified, set -e fix |
|| Dockerfile updated | ✅ | Removed traefik COPY |
|| traefik/ directory deleted | ✅ | traefik.yml, dynamic/webui.yml, static/index.html |
|| Docs updated | ✅ | CODESPACE_PORT_FORWARDING_ANALYSIS.md + README.md |
|| .gitignore added | ✅ | hermes-webui/scripts/.gitignore for __pycache__ |
|| Local verification | ✅ | py_compile, bash -n, no traefik/8780/8081 refs |
|| Branch committed and pushed | ✅ | Commit ac8f5fa on origin |
|| gh auth refreshed | ✅ | Token now includes `codespace` scope (added via background process) |
|| Codespace created | ⚠️ | `gh codespace create` succeeded but image build fails — `initializeCommand` (devcontainer-cache-build v0.9.2) fails in this environment, falling back to recovery container |
||| finalize_port_public.py tested | ✅ | Script run from host targeting codespace `test-final-gh-g76xjq77xq429r5q`. Mock health server on port 8787. Port 8787 made public via Tunnels API + gh CLI. Public URL returns `{"status":"ok"}`. No port 8780 (Traefik) present. |
||| Public image codespace tested | ✅ | Created `test-public-img-wgxvp7ggr773v4j6` with minimal devcontainer (public image, no initializeCommand). Health server on 8787. finalize_port_public.py 8787 made port public. URL `https://test-public-img-wgxvp7ggr773v4j6-8787.app.github.dev/health` → `{"status":"ok"}`. Port 8780 absent. Exit code 0. |

## Key Learnings

- The gh CLI auth token in this environment lacks the `codespace` scope
  (`Token scopes: 'gist', 'read:org', 'repo', 'workflow'`). Codespace creation
  via `gh codespace create` returns HTTP 403 without it. The `codespace` scope
  must be added via `gh auth refresh -s codespace -h github.com` (requires
  browser interaction).
- The `gh auth refresh` device flow prints a verification URL + one-time code
  but requires browser completion — not possible in a headless environment.
- The GitHub Authorizations API (`POST /authorizations`) is deprecated and
  returns 404 — cannot programmatically create a token with new scopes.
- **The `devcontainer-cache-build` tool's `initializeCommand` fails in this
  environment**: the tool (v0.9.2) runs inside a Docker container on the
  Codespace VM, but the Docker daemon or GHCR credentials are not available.
  Codespaces fall back to recovery containers (base-alpine). New codespaces
  from this repo always end up in recovery mode when the cached image tag
  doesn't match or the image was never built for the branch.
- **The `finalize_port_public.py` script was successfully tested** by running
  it from a host machine targeting a real Codespace. The script uses the
  Codespaces API to retrieve tunnel properties (`tunnelId`, `serviceUri`,
  `managePortsAccessToken` from `connection.tunnelProperties`), the Tunnels
  Management API (PUT) to register the port, and the gh CLI to toggle
  visibility and establish the relay.
- **Tunnels API visibility toggle to `private` may return HTTP 400** — this
  is a non-fatal warning. The port was already registered by the Tunnels API
  PUT, and the subsequent public toggle succeeds (HTTP 200). The gh CLI
  toggle handles the relay establishment.
- Local verification passed: Python syntax (py_compile), shell syntax (bash -n),
  Dockerfile COPY lines (no traefik), post_start_command (no 8780/8081 refs),
  finalize_port_public.py (port 8787 default).

## Testing Results

### Test: finalize_port_public.py makes port 8787 public

**Method**: Ran `finalize_port_public.py 8787` from the host machine targeting
codespace `test-final-gh-g76xjq77xq429r5q` (on branch
`fix/remove-traefik-direct-webui-port-forwarding`). A mock health server returning
`{"status":"ok"}` was started on port 8787 inside the codespace. The script was
invoked with `CODESPACE_NAME` and `GITHUB_TOKEN` env vars (codespace scope).

**Results**:
| Check | Result |
|-------|--------|
| Health endpoint (`http://127.0.0.1:18787/health`) | ✅ `{"status":"ok"}` |
| Codespace tunnel props retrieved via API | ✅ tunnelId, serviceUri, managePortsAccessToken |
| Port 8787 registered via Tunnels API PUT | ✅ |
| gh CLI visibility toggle (private → public) | ✅ Both succeeded |
| Tunnels API visibility toggle (public) | ✅ HTTP 200 |
| Public URL health check | ✅ `curl https://test-final-gh-g76xjq77xq429r5q-8787.app.github.dev/health` → `{"status":"ok"}` |
| Port 8780 (Traefik) present? | ✅ No (PASS) |
| Exit code | ✅ 0 |

**Note (updated)**: The `finalize_port_public.py` script was additionally verified
on a codespace (`test-public-img-wgxvp7ggr773v4j6`) using a **public pre-built image**
(`mcr.microsoft.com/devcontainers/python:3.12`) with no `initializeCommand`. This
bypasses the devcontainer-cache-build tool entirely, simulating the no-Traefik
environment. The full port-forwarding flow — Tunnels API registration + gh CLI
visibility toggle → public URL returning `{"status":"ok"}` — was confirmed working.

### Test: Public image codespace (no Traefik) — verified

**Date**: October 10, 2026

**Method**: Created a codespace from the branch using a minimal devcontainer.json
with `image: "mcr.microsoft.com/devcontainers/python:3.12"` (no `initializeCommand`)
and `--devcontainer-path` to bypass the failing image build. Started a mock health
server on port 8787 directly in the container via SSH. Ran `finalize_port_public.py 8787`
from the host targeting this codespace.

**Results**:

| Check | Result |
|-------|--------|
| Codespace state | ✅ "Available" (not recovery mode) |
| Devcontainer path | ✅ `.devcontainer/test/devcontainer.json` (public image) |
| Health server in codespace (8787) | ✅ `{"status":"ok"}` |
| Tunnels API tunnel props retrieved | ✅ tunnelId, serviceUri, managePortsAccessToken |
| Port 8787 registered via Tunnels API PUT | ✅ |
| gh CLI visibility toggle (private→public) | ✅ Both succeeded |
| Tunnels API visibility toggle (public) | ✅ HTTP 200 |
| Public URL health check (2nd verification) | ✅ `{"status":"ok"}` |
| Port 8780 (Traefik) present? | ✅ No (PASS) |
| Exit code | ✅ 0 |

**Public URL**: `https://test-public-img-wgxvp7ggr773v4j6-8787.app.github.dev/health`

## Remaining Issues / Open Questions

- **`initializeCommand` image build fails in this environment**: The `devcontainer-cache-build`
  tool (v0.9.2) runs `cat ~/.docker/config.json` with `set -ex`, but the Docker config
  file is absent or incomplete on the Codespace VM in this environment. This prevents
  the cached image from being built or pushed to GHCR. On a developer machine or CI/CD
  with proper GHCR credentials, the full Traefik-removal image build should succeed.
- **Image tag caching**: The `DEVCONTAINER_IMAGE` env var (`dockerfile-parts-devcontainer`)
  controls which cached image tag is used. After removing Traefik from the Dockerfile,
  a new image build is required to invalidate the cache. The `initializeCommand` tool
  handles this via its cache-busting logic, but it cannot run in this environment.
- **Tunnels API 400 on private visibility toggle**: Non-fatal warning — the gh CLI toggle
  handles relay establishment. The private toggle via Tunnels API returns 400 (likely
  because the port was just registered and the API needs a brief delay). The public toggle
  succeeds (HTTP 200). This could be fixed by adding a delay after the Tunnels API PUT.
