# Status: Hermes WebUI Codespace Port Forwarding Reliability

**Branch:** `61-webui-isnt-reliably-accessible-over-the-forwarded-port-on-codespace-launch`  
**Latest Commit:** `976b7c1` (fix: move initial tunnel props retrieval into retry loop)  
**Date:** 2026-09-28

## Goal

Make the Hermes WebUI reliably accessible over the Codespaces forwarded port (8780) — eliminate intermittent 404/ERR_INVALID_RESPONSE/000 errors on codespace startup and after stop/start cycles.

## Root Cause Analysis (Updated)

### What Actually Happens

After a codespace is created or started, the `post_start_command` runs `finalize_port_public.py`, which:

1. Gets tunnel connection properties via `GET /user/codespaces/{codespace_name}?internal=true&refresh=true`
2. Registers port 8780 on the VS Code Tunnels API (PUT)
3. Toggles visibility via `gh CLI` (`private → public`)
4. Verifies the public URL returns HTTP 200

**When run from the active codespace (animated-eureka)**: Steps 1-4 all succeed. Public URL returns 200.

**When run inside the test codespace's `post_start_command`**: Steps 1-3 may succeed (port registered on tunnel, `gh CLI` returns exit code 0), but the **tunnel proxy relay** (the WebSocket connection that forwards traffic from the public URL to the codespace's local port) is **not established**. The public URL times out (000/ERR_EMPTY_RESPONSE).

### Key Findings

1. **`?internal=true&refresh=true` works for Available codespaces**: The endpoint returns tunnel properties (`tunnelId`, `serviceUri`, `managePortsAccessToken`) for ANY Available codespace, not just the active session. The earlier 404 errors were from the **repo-scoped** endpoint (`/repos/{owner}/{repo}/codespaces/{name}`), which returns 404 for user-owned codespaces. The user-scoped endpoint (`/user/codespaces/{name}`) works correctly.

2. **Tunnels API PUT ≠ tunnel proxy relay**: Calling `PUT /tunnels/{tunnelId}/ports/{port}` with `Anonymous` access control registers the port on the tunnel object and sets access control entries. But it does **NOT** establish the tunnel proxy relay connection that forwards traffic from the public URL to the codespace's local port.

3. **The `gh CLI` visibility toggle establishes the relay**: The `gh codespace ports visibility` command internally calls `NewPortForwarder` which creates a host connection to the tunnel relay. This host connection is what establishes the forwarding path from the public URL to the local port. Without this host connection, the public URL times out even though the port appears as "public" in the tunnel.

4. **`post_start_command` runs inside the devcontainer**: When running from inside the devcontainer, the `gh CLI` is called as a subprocess with `GH_TOKEN` set. The auth works (exit code 0), but the port forwarder (tunnel relay connection) may not be establishing the host connection properly from inside the codespace's devcontainer.

5. **Manual `gh CLI` from another codespace works**: Running `gh codespace ports visibility 8780:private --codespace {test_codespace}` followed by `8780:public` from the active codespace establishes the tunnel relay connection and makes the public URL accessible within seconds.

6. **`set -euo pipefail` in `post_start_command`**: The `post_start_command` script uses `set -euo pipefail`, which causes any command failure to exit the script. If `finalize_port_public.py` exits with a non-zero code, the `post_start_command` chain exits. The script should be made resilient to this with `|| true` or the `set -e` should be temporarily disabled for the script call.

7. **Docker layer caching in codespace builds**: The test codespace's Docker image is built from the branch when the codespace is created. Changes to `post_start_command` and `finalize_port_public.py` must be committed AND the test codespace must be created fresh (new image build) for changes to take effect.

## Files Changed (on this branch)

| File | Status | Description |
|------|--------|-------------|
| `hermes-webui/scripts/finalize_port_public.py` | Modified | Added user-scoped endpoint fallback, 5-minute retry loop, gh CLI visibility toggle, verbose stderr logging, moved tunnel props retrieval into retry loop |
| `hermes-webui/post_start_command` | Modified | Added GH_TOKEN export before finalize_port_public.py; added debug logging to debug.log + exit_code.txt |
| `hermes-webui/scripts/.gitignore` | New | Ignores `__pycache__/` |
| `CODESPACE_PORT_FORWARDING_ANALYSIS.md` | Modified | Updated with API investigation and test results |

## Fixes Applied (Committed)

1. **Commit `15ade7a`**: Export `GH_TOKEN` in `post_start_command` before calling `finalize_port_public.py` — ensures `gh CLI` subprocess has proper auth
2. **Commit `220258a`**: Fallback to user-scoped Codespace API endpoint (`GET /user/codespaces/{name}?internal=true`) when repo-scoped (`GET /repos/{owner}/{repo}/codespaces/{name}`) returns 404
3. **Commit `63655fe`**: Add verbose stderr logging in `set_port_visibility` for gh CLI visibility toggle
4. **Commit `9a63302`**: Write debug log to web-accessible static dir (`/opt/devcontainers/hermes-webui/traefik/static/debug.log`)
5. **Commit `976b7c1`**: Move initial tunnel props retrieval into retry loop so it retries when props aren't immediately available

## Testing Results

### What Works
- **Fresh codespace via `gh codespace create`**: Port 8780 is public and accessible immediately (200)
- **Manual `gh CLI` visibility toggle**: `gh codespace ports visibility 8780:private` then `8780:public` fixes the public endpoint (200)
- **Running `finalize_port_public.py` from the active codespace** targeting another codespace: Works (public URL returns 200)
- **Running `finalize_port_public.py` with correct env vars set** (CODESPACE_NAME, GH_TOKEN): Works

### What Fails
- **`post_start_command` inside test codespace devcontainer**: After `post_start_command` completes, the public URL times out (000/TimeoutError). Manual intervention required.
- **Docker image caching**: The Docker image baked into the codespace may not include the latest `post_start_command` and `finalize_port_public.py` changes if the codespace wasn't freshly created from the latest commit.

## TODO / Next Steps

### Immediate (Required)
1. **Investigate `gh CLI` failure inside devcontainer**: The `gh CLI` visibility toggle (`gh codespace ports visibility`) should establish the tunnel relay host connection. Verify:
   - `gh CLI` is in PATH inside the devcontainer
   - `GH_TOKEN` is properly exported (check via debug log)
   - `gh CLI` stderr/stdout for error output
2. **Make `post_start_command` resilient**: Wrap `finalize_port_public.py` call with `|| true` to prevent `set -e` from killing the script on failure, and add a fallback retry mechanism
3. **Verify with fresh codespace**: After committing fixes, create a new test codespace (not rebuild) and verify:
   - Fresh start: Port 8780 public immediately
   - Stop/start: Port 8780 public after start
4. **Access debug.log**: Add a route or mechanism to access `debug.log` via the public URL (e.g., serve it via the landing page or an API endpoint), so failures can be diagnosed without SSH
