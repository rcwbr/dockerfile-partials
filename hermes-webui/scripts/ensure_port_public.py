#!/usr/bin/env python3
"""Ensure a Codespace port is registered as public via the Tunnels Management API.

This script replaces the inline bash port-publishing logic in post_start_command.
It:
  1. Detects CODESPACE_NAME (from env or shared .env file)
  2. Reads GITHUB_TOKEN for auth
  3. Queries the Codespace details API for tunnel connection properties
  4. Creates the port on the Codespace's VS Code Tunnel via PUT
  5. Verifies the port is publicly accessible

Usage: ensure_port_public.py [PORT]
       Default PORT = 8780
"""

import json
import os
import sys
import subprocess
import urllib.request

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

    # 1. Get Codespace name
    codespace_name = get_codespace_name()
    if not codespace_name:
        print('Not running in a Codespace — skipping public port setup', file=sys.stderr)
        sys.exit(0)

    # 2. Get GitHub token
    token = get_github_token()
    if not token:
        print('[error] GITHUB_TOKEN not found in env or shared .env', file=sys.stderr)
        sys.exit(1)

    # 3. Verify gh authentication
    auth_check = subprocess.run(['gh', 'auth', 'status'], capture_output=True, env={**os.environ, 'GH_TOKEN': token})
    if auth_check.returncode != 0:
        print('[error] gh CLI is not authenticated — cannot set port visibility', file=sys.stderr)
        sys.exit(1)

    # 4. Get Codespace tunnel properties
    print(f"Making port {port} public on Codespace: {codespace_name}")
    cs_info = gh_api(f"/user/codespaces/{codespace_name}?internal=true&refresh=true", token)

    tunnel_props = cs_info.get('connection', {}).get('tunnelProperties', {})
    tunnel_id = tunnel_props.get('tunnelId', '')
    tunnel_token = tunnel_props.get('managePortsAccessToken', '')
    service_uri = tunnel_props.get('serviceUri', '')

    if not tunnel_id or not tunnel_token or not service_uri:
        print('[error] Missing tunnel connection properties', file=sys.stderr)
        sys.exit(1)

    # 5. Create port on the tunnel
    print(f"Registering port {port} via Tunnels Management API...")
    create_resp = tunnels_api_put(service_uri, tunnel_id, tunnel_token, port)

    # 6. Verify
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
