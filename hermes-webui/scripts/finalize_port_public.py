#!/usr/bin/env python3
"""Ensure Codespace port is public via Tunnels Management API, with health polling.

This script replaces the inline bash port-publishing logic in post_start_command.
It:
  1. Polls the Hermes WebUI /health endpoint until status == "ok" (max 120s)
  2. If not in a Codespace, exits successfully (no-op)
  3. If in a Codespace: detects name, reads GitHub token, queries the Codespace
     details API for tunnel connection properties, creates the port on the VS Code
     Tunnel via PUT, refreshes tunnel visibility to fix stale entries, and verifies
     the port is publicly accessible via HTTP polling. Retries the entire
     register+toggle cycle for up to 5 minutes if the endpoint fails.

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
    """Poll /health until it returns status == "ok" or timeout expires."""
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


def get_codespace_tunnel_props(codespace_name: str, token: str) -> dict:
    """Get tunnel connection properties (tunnelId, serviceUri, managePortsAccessToken)
    for the given codespace via the GitHub Codespaces REST API.
    """
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    if repo:
        cs_endpoint = f'/repos/{repo}/codespaces/{codespace_name}?internal=true&refresh=true'
    else:
        cs_endpoint = f'/user/codespaces/{codespace_name}?internal=true&refresh=true'
    cs_info = gh_api(cs_endpoint, token)
    tunnel_props = cs_info.get('connection', {}).get('tunnelProperties', {})
    tunnel_id = tunnel_props.get('tunnelId', '')
    tunnel_token = tunnel_props.get('managePortsAccessToken', '')
    service_uri = tunnel_props.get('serviceUri', '')
    if not tunnel_id or not tunnel_token or not service_uri:
        raise ValueError('Missing tunnel connection properties')
    return {
        'tunnel_id': tunnel_id,
        'tunnel_token': tunnel_token,
        'service_uri': service_uri,
    }


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


def tunnels_api_get_port(service_uri: str, tunnel_id: str, token: str, port: int) -> dict:
    """Get existing port info from the Tunnels API."""
    url = f'{service_uri}tunnels/{tunnel_id}/ports/{port}?api-version=2023-09-27-preview'
    req = urllib.request.Request(
        url,
        headers={'Authorization': f'Tunnel {token}'},
        method='GET',
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        print(f'[warn] Could not GET existing port info: {e}', file=sys.stderr)
        return {}


def tunnels_api_set_visibility(service_uri: str, tunnel_id: str, token: str, port: int,
                                visibility: str) -> bool:
    """Set port visibility via the VS Code Tunnels Management API directly.

    This replicates what 'gh codespace ports visibility' does internally.
    The Tunnels API controls the access control entries on the port, which
    forces the tunnel proxy to tear down and recreate its forwarding path.
    This fixes stale tunnel entries that return 404 despite showing as public.

    Args:
        service_uri: The tunnel service URI from codespace connection tunnelProperties
        tunnel_id: The tunnel ID from codespace connection tunnelProperties
        token: The managePortsAccessToken from codespace connection tunnelProperties
        port: The port number to update
        visibility: 'public', 'private', or 'org'

    Returns True if the API PUT succeeded, False otherwise.
    """
    # Get the current port info to preserve protocol/labels
    port_info = tunnels_api_get_port(service_uri, tunnel_id, token, port)

    # Build access control entries based on desired visibility
    # Reference: https://github.com/microsoft/dev-tunnels/blob/main/docs/tunnelAccessControl.md
    if visibility == 'public':
        # Public = anyone with the link (Anonymous with connect scope)
        access_control = {
            'entries': [
                {
                    'type': 'Anonymous',
                    'subjects': [],
                    'scopes': ['connect'],
                }
            ]
        }
    elif visibility == 'private':
        # Private = only the tunnel owner (Authenticated via GitHub auth)
        access_control = {
            'entries': [
                {
                    'type': 'Authenticated',
                    'subjects': [],
                    'scopes': ['connect'],
                }
            ]
        }
    elif visibility == 'org':
        # Org = organization members
        access_control = {
            'entries': [
                {
                    'type': 'OrganizationalAccount',
                    'subjects': [],
                    'scopes': ['connect'],
                }
            ]
        }
    else:
        print(f'[error] Unknown visibility: {visibility}', file=sys.stderr)
        return False

    put_body = {
        'portNumber': port,
        'protocol': port_info.get('protocol', 'http'),
        'labels': port_info.get('labels', []),
        'accessControl': access_control,
        'options': port_info.get('options', {
            'isGloballyAvailable': visibility == 'public',
        }),
    }

    put_url = f'{service_uri}tunnels/{tunnel_id}/ports/{port}?api-version=2023-09-27-preview'
    req = urllib.request.Request(
        put_url,
        data=json.dumps(put_body).encode(),
        headers={
            'Authorization': f'Tunnel {token}',
            'Content-Type': 'application/json',
        },
        method='PUT',
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f'Visibility set to {visibility} via Tunnels API (status: {resp.status})')
            return True
    except Exception as e:
        print(f'[warn] Tunnels API visibility update to {visibility} failed: {e}',
              file=sys.stderr)
        return False


def set_port_visibility(codespace_name: str, port: int, visibility: str, token: str) -> bool:
    """Set port visibility via the Codespaces connection + Tunnels Management API.

    Uses the codespace connection properties to get the tunnel service URI and
    auth token, then calls the Tunnels API to update port visibility.

    This fixes stale tunnel entries that return 404 despite showing as public
    on codespace rebuilds, because toggling visibility forces the tunnel proxy
    to tear down and recreate the forwarding path.
    """
    try:
        tunnel_props = get_codespace_tunnel_props(codespace_name, token)
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError) as e:
        print(f'[warn] Could not retrieve Codespace connection for visibility toggle: {e}',
              file=sys.stderr)
        return False

    return tunnels_api_set_visibility(
        tunnel_props['service_uri'],
        tunnel_props['tunnel_id'],
        tunnel_props['tunnel_token'],
        port,
        visibility,
    )


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

    # Construct URL from codespace name + port (standard pattern)
    return f'https://{codespace_name}-{port}.app.github.dev'


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


def finalize_port_public(public_url: str, codespace_name: str, port: int, token: str,
                         tunnel_props: dict) -> bool:
    """One iteration of port registration + visibility toggle + verification.

    Returns True if the public endpoint is verified, False otherwise.
    """
    service_uri = tunnel_props['service_uri']
    tunnel_id = tunnel_props['tunnel_id']
    tunnel_token = tunnel_props['tunnel_token']

    # 1. Re-register the port on the tunnel
    print(f'Registering port {port} via Tunnels Management API...')
    create_resp = tunnels_api_put(service_uri, tunnel_id, tunnel_token, port)

    # 2. Toggle visibility (private→public) to force tunnel proxy to refresh
    print('Toggling port visibility to force tunnel proxy refresh...')
    set_port_visibility(codespace_name, port, 'private', token)
    time.sleep(2)
    set_port_visibility(codespace_name, port, 'public', token)

    # 3. Verify the public endpoint is accessible
    return verify_public_endpoint(public_url, timeout=30)


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
    try:
        tunnel_props = get_codespace_tunnel_props(codespace_name, token)
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        print('[error] Could not retrieve Codespace details — cannot set port visibility',
              file=sys.stderr)
        print(f'[error] {e}', file=sys.stderr)
        sys.exit(1)
    except ValueError as e:
        print(f'[error] {e}', file=sys.stderr)
        sys.exit(1)

    # 5. Determine public URL (constructed from standard pattern)
    public_url = f'https://{codespace_name}-{port}.app.github.dev'

    # 6. Retry loop: re-register port + toggle visibility until endpoint works
    # On codespace rebuilds, the Codespaces tunnel proxy may retain a stale
    # forwarding entry. Toggling visibility and re-registering forces the
    # tunnel proxy to tear down and recreate its forwarding path.
    # Timeout: 5 minutes (300 seconds), with ~25s per iteration
    total_timeout = 300
    print(f'Entering retry loop (timeout={total_timeout}s) to make {public_url} accessible...')
    deadline = time.time() + total_timeout

    while time.time() < deadline:
        # Refresh tunnel props in case they rotate
        try:
            tunnel_props = get_codespace_tunnel_props(codespace_name, token)
        except (urllib.error.HTTPError, urllib.error.URLError, ValueError):
            pass  # Keep using cached props

        if finalize_port_public(public_url, codespace_name, port, token, tunnel_props):
            print(f'Port {port} is now publicly accessible')
            print(f'URL: {public_url}')
            sys.exit(0)

        remaining = int(deadline - time.time())
        if remaining > 0:
            print(f'Retry failed, retrying in 5s ({remaining}s remaining)...')
            time.sleep(5)

    # All retries exhausted
    print(f'[error] Failed to make port {port} publicly accessible after {total_timeout}s',
          file=sys.stderr)
    print(f'[error] Last checked: {public_url}', file=sys.stderr)
    print(f'[error] Try toggling visibility manually:', file=sys.stderr)
    print(f'  gh codespace ports visibility {port}:private --codespace {codespace_name}')
    print(f'  gh codespace ports visibility {port}:public --codespace {codespace_name}')
    sys.exit(1)


if __name__ == '__main__':
    main()
