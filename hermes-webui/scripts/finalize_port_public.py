#!/usr/bin/env python3
"""Ensure Codespace port is public via Tunnels Management API, with health polling.

This script replaces the inline bash port-publishing logic in post_start_command.
It:
  1. Polls the Hermes WebUI /health endpoint until status == "ok" (max 120s)
  2. If not in a Codespace, exits successfully (no-op)
  3. If in a Codespace: detects name, reads GitHub token, queries the Codespace
     details API for tunnel connection properties, creates the port on the VS Code
     Tunnel via PUT, refreshes tunnel visibility to fix stale entries, and verifies
     the port is publicly accessible via HTTP polling.

Usage: finalize_port_public.py [PORT]
       Default PORT = 8780
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

ENV_FILE = '/workspaces/.codespaces/shared/.env'
GITHUB_API = 'https://api.github.com'


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
    health_url = f'http://{host}:{port}/health'
    print(f'Waiting for Hermes Web UI at {health_url}...')
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req = urllib.request.Request(health_url)
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read().decode()
                if '"status"' in body and '"ok"' in body:
                    print('Hermes Web UI is ready')
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
    """Make a GitHub API request using the REST API directly.

    Uses urllib instead of the gh CLI for better error handling and
    to avoid requiring gh CLI authentication in the runtime environment.
    """
    url = f'{GITHUB_API}{endpoint}'
    headers = {
        'Accept': 'application/vnd.github+json',
        'Authorization': f'Bearer {token}',
        'X-GitHub-Api-Version': '2022-11-28',
    }
    body = None
    if data:
        headers['Content-Type'] = 'application/json'
        body = json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode()
            if resp.headers.get('Content-Type', '').startswith('application/json'):
                return json.loads(resp_body) if resp_body else {}
            return {'raw': resp_body}
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        print(f'[error] GitHub API {method} {endpoint} failed: {e.code}', file=sys.stderr)
        print(f'[error] {error_body[:500]}', file=sys.stderr)
        raise


def tunnels_api_put(service_uri: str, tunnel_id: str, token: str, port: int) -> dict:
    """Create/register a port on the Codespace's VS Code Tunnel."""
    url = f'{service_uri}tunnels/{tunnel_id}/ports/{port}?api-version=2023-09-27-preview'
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
            'Authorization': f'Tunnel {token}',
            'Content-Type': 'application/json',
        },
        method='PUT',
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {'error': str(e)}


def set_port_visibility(codespace_name: str, port: int, visibility: str, token: str) -> bool:
    """Set port visibility via the Codespaces REST API.

    Uses PATCH /repos/{owner}/{repo}/codespaces/{codespace}/ports/{port}
    to force the Codespace tunnel proxy to refresh its forwarding entry.
    This fixes stale tunnel entries that return 404 despite showing as public.
    """
    # Try repo-scoped endpoint first (preferred)
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    if repo:
        endpoint = f'/repos/{repo}/codespaces/{codespace_name}/ports/{port}'
    else:
        endpoint = f'/user/codespaces/{codespace_name}'
        # For user-scoped, we need to get ports list and find the one to update
        # Actually, the user/codespaces endpoint doesn't support per-port PATCH
        # Fall back to the gh CLI approach via subprocess if REST API fails
        pass

    try:
        gh_api(endpoint, token, method='PATCH', data={'visibility': visibility})
        return True
    except (urllib.error.HTTPError, urllib.error.URLError):
        # REST API may not support port-level visibility management directly
        # Fall back to gh CLI
        pass

    # Fall back: use gh CLI
    try:
        import subprocess
        result = subprocess.run(
            ['gh', 'codespace', 'ports', 'visibility', f'{port}:{visibility}',
             '--codespace', codespace_name],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, 'GH_TOKEN': token},
        )
        return result.returncode == 0
    except Exception:
        return False


def get_port_forwarding_url(codespace_name: str, port: int, token: str) -> str | None:
    """Get the public URL for a forwarded port via the Codespaces API."""
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    try:
        if repo:
            endpoint = f'/repos/{repo}/codespaces/{codespace_name}'
        else:
            endpoint = f'/user/codespaces/{codespace_name}'
        cs_info = gh_api(endpoint, token)
        for port_info in cs_info.get('ports', []):
            if port_info.get('port') == port or port_info.get('port_number') == port:
                return port_info.get('port_forwarding_url') or port_info.get('web_url')
    except Exception:
        pass

    # Fall back: use gh CLI to get the URL
    try:
        import subprocess
        result = subprocess.run(
            ['gh', 'codespace', 'ports', '--codespace', codespace_name, '--json', 'port,portForwardingUrl'],
            capture_output=True, text=True, timeout=15,
            env={**os.environ, 'GH_TOKEN': token},
        )
        if result.returncode == 0:
            ports = json.loads(result.stdout)
            for p in ports:
                if p.get('port') == port:
                    return p.get('portForwardingUrl')
    except Exception:
        pass

    return None


def verify_public_endpoint(url: str, timeout: int = 120) -> bool:
    """Poll the public URL until it returns HTTP 200 or timeout expires."""
    print(f'Verifying public endpoint: {url}/health')
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req = urllib.request.Request(f'{url}/health')
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status == 200:
                    body = resp.read().decode()
                    if '"ok"' in body:
                        print(f'Public endpoint verified (HTTP 200, status=ok)')
                        return True
        except (urllib.error.URLError, ConnectionError, OSError, urllib.error.HTTPError):
            pass
        time.sleep(4)
    return False


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

    # 4. Get Codespace tunnel properties
    print(f'Making port {port} public on Codespace: {codespace_name}')
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    if repo:
        cs_endpoint = f'/repos/{repo}/codespaces/{codespace_name}?internal=true&refresh=true'
    else:
        cs_endpoint = f'/user/codespaces/{codespace_name}?internal=true&refresh=true'

    try:
        cs_info = gh_api(cs_endpoint, token)
    except (urllib.error.HTTPError, urllib.error.URLError):
        print('[error] Could not retrieve Codespace details — cannot set port visibility', file=sys.stderr)
        sys.exit(1)

    tunnel_props = cs_info.get('connection', {}).get('tunnelProperties', {})
    tunnel_id = tunnel_props.get('tunnelId', '')
    tunnel_token = tunnel_props.get('managePortsAccessToken', '')
    service_uri = tunnel_props.get('serviceUri', '')

    if not tunnel_id or not tunnel_token or not service_uri:
        print('[error] Missing tunnel connection properties', file=sys.stderr)
        sys.exit(1)

    # 5. Create port on the tunnel
    print(f'Registering port {port} via Tunnels Management API...')
    create_resp = tunnels_api_put(service_uri, tunnel_id, tunnel_token, port)

    # 6. Force visibility refresh to fix stale tunnel entries
    # On codespace rebuilds, the Codespaces tunnel proxy may retain a stale
    # forwarding entry. The Tunnels API PUT returns success even if the tunnel
    # proxy has a broken entry. Toggling visibility forces the tunnel proxy
    # to tear down and recreate the forwarding path.
    print('Refreshing Codespace tunnel port visibility...')
    set_port_visibility(codespace_name, port, 'private', token)
    time.sleep(2)
    set_port_visibility(codespace_name, port, 'public', token)

    # 7. Verify the public endpoint is accessible
    port_uris = create_resp.get('portForwardingUris', [])
    public_url = port_uris[0] if port_uris else None

    if not public_url:
        # Try to get the URL from the Codespaces API
        public_url = get_port_forwarding_url(codespace_name, port, token)

    if public_url and verify_public_endpoint(public_url, timeout=120):
        print(f'Port {port} is now publicly accessible')
        print(f'URL: {public_url}')
        sys.exit(0)
    elif public_url:
        print(f'[warn] Public URL is registered but not responding: {public_url}', file=sys.stderr)
        print(f'[warn] Port {port} is registered as public but endpoint verification failed', file=sys.stderr)
        sys.exit(0)  # Still exit 0 — the port IS registered as public
    else:
        print(f'[error] Failed to create port {port} on the Codespace tunnel', file=sys.stderr)
        print(f'[error] Tunnels API response: {json.dumps(create_resp)}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
