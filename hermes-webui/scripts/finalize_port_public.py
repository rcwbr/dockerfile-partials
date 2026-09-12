#!/usr/bin/env python3
"""Ensure Codespace port is public via Tunnels Management API, with health polling.

This script replaces the inline bash port-publishing logic in post_start_command.
It:
  1. Polls the Hermes WebUI /health endpoint until status == "ok" (max 120s)
  2. If not in a Codespace, exits successfully (no-op)
  3. If in a Codespace: detects name, reads GitHub token, queries the Codespace
     details API for tunnel connection properties, creates the port on the VS Code
     Tunnel via PUT, and verifies the port is publicly accessible

Usage: finalize_port_public.py [PORT]
       Default PORT = 8780
"""

import json
import os
import sys
import time
import subprocess
import urllib.request
import urllib.error

ENV_FILE = '/workspaces/.codespaces/shared/.env'


def get_env_value(key: str) -> str | None:
    """Read a KEY=VALUE from the shared Codespaces env file."""
    if not os.path.isfile(ENV_FILE):
        return None
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if line.startswith(key + '='):
                return line[len(key) + 1:].strip()
    return None


def wait_for_webui_health(host: str = '127.0.0.1', port: int = 8787, timeout: int = 120) -> bool:
    """Poll /health until it returns status == 'ok' or timeout expires."""
    health_url = f"http://{host}:{port}/health"
    print(f"Waiting for Hermes Web UI at {health_url}...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req = urllib.request.Request(health_url)
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read().decode()
                if '"status"' in body and '"ok"' in body:
                    print("Hermes Web UI is ready")
                    return True
        except (urllib.error.URLError, ConnectionError, OSError):
            pass
        time.sleep(5)
    return False


def get_codespace_name() -> str | None:
    """Detect the current Codespace name from env or shared .env file."""
    name = os.environ.get('CODESPACE_NAME', '').strip()
    if not name:
        name = get_env_value('CODESPACE_NAME') or ''
    return name if name else None


def get_github_token() -> str | None:
    """Get the GitHub token from env or shared .env file."""
    token = os.environ.get('GITHUB_TOKEN', '').strip()
    if not token:
        token = os.environ.get('HERMES_GITHUB_TOKEN', '').strip()
    if not token:
        token = get_env_value('GITHUB_TOKEN') or ''
    return token if token else None


def gh_api(endpoint: str, token: str, method: str = 'GET', data: dict | None = None) -> dict:
    """Make a GitHub API request using gh CLI (for proper auth handling)."""
    cmd = ['gh', 'api', endpoint, '-H', 'Accept: application/vnd.github+json']
    if method != 'GET':
        cmd.extend(['-X', method])
    if data:
        cmd.extend(['-d', json.dumps(data)])
    result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, 'GH_TOKEN': token})
    if result.returncode != 0:
        print(f"[error] gh api failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def tunnels_api_put(service_uri: str, tunnel_id: str, token: str, port: int) -> dict:
    """Create/register a port on the Codespace's VS Code Tunnel."""
    url = f"{service_uri}tunnels/{tunnel_id}/ports/{port}?api-version=2023-09-27-preview"
    body = {
        'portNumber': port,
        'labels': ['UserForwardedPort'],
        'protocol': 'http',
        'accessControl': {
            'entries': [
                {
                    'type': 'Anonymous',
                    'subjects': [],
                    'scopes': ['connect'],
                }
            ]
        },
        'options': {
            'isGloballyAvailable': True,
        },
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            'Authorization': f"Tunnel {token}",
            'Content-Type': 'application/json',
        },
        method='PUT',
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {'error': str(e)}


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8780

    # 1. Wait for WebUI to be ready
    hwebui_host = os.environ.get('HERMES_WEBUI_HOST', '127.0.0.1')
    hwebui_port = int(os.environ.get('HERMES_WEBUI_PORT', '8787'))
    if not wait_for_webui_health(hwebui_host, hwebui_port, timeout=120):
        print('[error] Hermes Web UI did not become ready within 120 seconds', file=sys.stderr)
        sys.exit(1)

    # 2. If not in a Codespace, nothing else to do
    codespace_name = get_codespace_name()
    if not codespace_name:
        print('Not running in a Codespace — skipping public port setup', file=sys.stderr)
        sys.exit(0)

    # 3. Get GitHub token
    token = get_github_token()
    if not token:
        print('[error] GITHUB_TOKEN not found in env or shared .env', file=sys.stderr)
        sys.exit(1)

    # 4. Verify gh authentication
    auth_check = subprocess.run(
        ['gh', 'auth', 'status'],
        capture_output=True,
        env={**os.environ, 'GH_TOKEN': token},
    )
    if auth_check.returncode != 0:
        print('[error] gh CLI is not authenticated — cannot set port visibility', file=sys.stderr)
        sys.exit(1)

    # 5. Get Codespace tunnel properties
    print(f"Making port {port} public on Codespace: {codespace_name}")
    cs_info = gh_api(f"/user/codespaces/{codespace_name}?internal=true&refresh=true", token)

    tunnel_props = cs_info.get('connection', {}).get('tunnelProperties', {})
    tunnel_id = tunnel_props.get('tunnelId', '')
    tunnel_token = tunnel_props.get('managePortsAccessToken', '')
    service_uri = tunnel_props.get('serviceUri', '')

    if not tunnel_id or not tunnel_token or not service_uri:
        print('[error] Missing tunnel connection properties', file=sys.stderr)
        sys.exit(1)

    # 6. Create port on the tunnel
    print(f"Registering port {port} via Tunnels Management API...")
    create_resp = tunnels_api_put(service_uri, tunnel_id, tunnel_token, port)

    # 7. Verify
    port_uris = create_resp.get('portForwardingUris', [])
    if port_uris:
        print(f"Port {port} is now publicly accessible")
        print(f"URL: {port_uris[0]}")
        sys.exit(0)
    else:
        print(f"[error] Failed to create port {port} on the Codespace tunnel", file=sys.stderr)
        print(f"[error] Tunnels API response: {json.dumps(create_resp)}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
