#!/usr/bin/env python3
"""Ensure Codespace port is public via Tunnels Management API, with health polling.

This script replaces the inline bash port-publishing logic in post_start_command.
It:
  1. Polls the Hermes WebUI /health endpoint until status == "ok" (max 120s)
  2. If not in a Codespace, exits successfully (no-op)
  3. If in a Codespace: detects name, reads GitHub token, queries the Codespace
     details API for tunnel connection properties, registers the port on the
     VS Code tunnel via PUT, and establishes a tunnel relay host connection
     using the connectAccessToken. Retries for up to 5 minutes.

Usage: finalize_port_public.py [PORT]
       Default PORT = 8780
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
import subprocess

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
    """Get the GitHub token from env or shared .env file.

    Priority:
      1. HERMES_GITHUB_TOKEN env var (codespace-specific token)
      2. GITHUB_TOKEN env var (from env or post_start_command export)
      3. HERMES_GITHUB_TOKEN from .env file
      4. GITHUB_TOKEN from .env file
    """
    token = os.environ.get('HERMES_GITHUB_TOKEN', '').strip()
    if not token:
        token = os.environ.get('GITHUB_TOKEN', '').strip()
    if not token:
        token = get_env_value('HERMES_GITHUB_TOKEN') or ''
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
    """Get tunnel connection properties (tunnelId, serviceUri, tokens)
    for the given codespace via the GitHub Codespaces REST API.

    Uses the user-scoped endpoint with ?internal=true&refresh=true.
    Retry with a short delay in case the tunnel properties are briefly unavailable.
    """
    # Try user-scoped endpoint first; repo-scoped as fallback
    repo = os.environ.get('GITHUB_REPOSITORY', '')
    endpoints_to_try = [f'/user/codespaces/{codespace_name}?internal=true&refresh=true']
    if repo:
        endpoints_to_try.append(f'/repos/{repo}/codespaces/{codespace_name}?internal=true&refresh=true')

    last_error = None
    for attempt in range(3):
        for endpoint in endpoints_to_try:
            try:
                cs_info = gh_api(endpoint, token)
                tunnel_props = cs_info.get('connection', {}).get('tunnelProperties', {})
                tunnel_id = tunnel_props.get('tunnelId', '')
                tunnel_token = tunnel_props.get('managePortsAccessToken', '')
                service_uri = tunnel_props.get('serviceUri', '')
                connect_token = tunnel_props.get('connectAccessToken', '')
                if tunnel_id and tunnel_token and service_uri:
                    return {
                        'tunnel_id': tunnel_id,
                        'manage_token': tunnel_token,
                        'connect_token': connect_token,
                        'service_uri': service_uri,
                    }
            except (urllib.error.HTTPError, urllib.error.URLError) as e:
                last_error = e
                continue
        if attempt < 2:
            print(f'[warn] Tunnel props attempt {attempt+1} failed, retrying in 5s: {last_error}',
                  file=sys.stderr)
            time.sleep(5)

    raise ValueError(f'Could not retrieve tunnel connection properties: {last_error}')


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
    except urllib.error.HTTPError as e:
        print(f'[warn] Tunnels API PUT failed: HTTP {e.code} - {e.read().decode()[:200]}', file=sys.stderr)
        return {}
    except Exception as e:
        print(f'[warn] Tunnels API PUT failed: {e}', file=sys.stderr)
        return {}


def tunnels_api_set_visibility(service_uri: str, tunnel_id: str, token: str, port: int,
                               visibility: str) -> bool:
    """Set port visibility via the VS Code Tunnels Management API directly.

    Updates access control entries on the port to change visibility.
    """
    # Get existing port info
    port_url = f'{service_uri}tunnels/{tunnel_id}/ports/{port}?api-version=2023-09-27-preview'
    port_info = {}
    try:
        req = urllib.request.Request(port_url, headers={'Authorization': f'Tunnel {token}'})
        with urllib.request.urlopen(req, timeout=10) as resp:
            port_info = json.loads(resp.read().decode())
    except Exception:
        pass

    if visibility == 'public':
        access_control = {'entries': [{'type': 'Anonymous', 'subjects': [], 'scopes': ['connect']}]}
    elif visibility == 'private':
        access_control = {'entries': [{'type': 'Authenticated', 'subjects': [], 'scopes': ['connect']}]}
    else:
        access_control = port_info.get('accessControl', {'entries': []})

    put_body = {
        'portNumber': port,
        'protocol': port_info.get('protocol', 'http'),
        'labels': port_info.get('labels', []),
        'accessControl': access_control,
        'options': port_info.get('options', {'isGloballyAvailable': visibility == 'public'}),
    }

    req = urllib.request.Request(
        port_url,
        data=json.dumps(put_body).encode(),
        headers={'Authorization': f'Tunnel {token}', 'Content-Type': 'application/json'},
        method='PUT',
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f'Visibility set to {visibility} via Tunnels API (status: {resp.status})')
            return True
    except Exception as e:
        print(f'[warn] Tunnels API visibility update to {visibility} failed: {e}', file=sys.stderr)
        return False


def gh_cli_set_visibility(codespace_name: str, port: int, visibility: str, token: str) -> bool:
    """Set port visibility using the gh CLI.

    The gh CLI goes through the Codespace connection layer, which properly
    signals the tunnel proxy to re-establish its forwarding path.
    """
    try:
        result = subprocess.run(
            ['gh', 'codespace', 'ports', 'visibility', f'{port}:{visibility}',
             '--codespace', codespace_name],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, 'GH_TOKEN': token, 'GITHUB_TOKEN': token},
        )
        if result.stdout:
            print(f'  gh CLI stdout: {result.stdout.strip()[:200]}')
        if result.stderr:
            print(f'  gh CLI stderr: {result.stderr.strip()[:300]}', file=sys.stderr)
        if result.returncode == 0:
            print(f'Visibility set to {visibility} via gh CLI')
            return True
        else:
            print(f'[warn] gh CLI visibility toggle failed: {result.stderr.strip()[:200]}',
                  file=sys.stderr)
            return False
    except subprocess.TimeoutExpired:
        print(f'[warn] gh CLI timed out setting visibility to {visibility}', file=sys.stderr)
        return False
    except Exception as e:
        print(f'[warn] gh CLI error: {e}', file=sys.stderr)
        return False


def set_port_visibility(codespace_name: str, port: int, visibility: str, token: str,
                        tunnel_props: dict) -> bool:
    """Set port visibility using BOTH Tunnels API and gh CLI.

    Order matters: call the gh CLI FIRST (which retrieves fresh tunnel properties
    via GetCodespaceConnection and creates a port forwarder that establishes the
    host connection on the tunnel relay). Then use the Tunnels API to ensure
    the access control is set correctly.

    The gh CLI may fail with 404 if the port isn't registered yet — in that case,
    the Tunnels API PUT (called separately in finalize_port_public) handles
    registration, and the gh CLI can be retried.
    """
    # 1. Try gh CLI first — it retrieves fresh tunnel properties and creates
    #    a port forwarder that establishes the host connection
    gh_result = gh_cli_set_visibility(codespace_name, port, visibility, token)

    # 2. Also try Tunnels API (works even if gh CLI fails)
    try:
        tunnels_api_set_visibility(
            tunnel_props['service_uri'],
            tunnel_props['tunnel_id'],
            tunnel_props['manage_token'],
            port,
            visibility,
        )
    except Exception as e:
        print(f'[warn] Tunnels API visibility toggle failed: {e}', file=sys.stderr)

    return gh_result


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


def finalize_port_public(public_url: str, codespace_name: str, port: int, token: str) -> bool:
    """One iteration of port registration + visibility toggle + verification.

    Returns True if the public endpoint is verified, False otherwise.
    """
    # Get fresh tunnel properties
    try:
        tunnel_props = get_codespace_tunnel_props(codespace_name, token)
    except ValueError as e:
        print(f'[warn] Could not get tunnel props: {e}', file=sys.stderr)
        return False

    service_uri = tunnel_props['service_uri']
    tunnel_id = tunnel_props['tunnel_id']
    manage_token = tunnel_props['manage_token']

    # 1. Register the port on the Tunnels API
    print(f'Registering port {port} via Tunnels Management API...')
    tunnels_api_put(service_uri, tunnel_id, manage_token, port)

    # 2. Toggle visibility (private→public) to establish relay connection
    print('Toggling port visibility to establish relay connection...')
    # Order: gh CLI first (establishes host connection), then Tunnels API
    set_port_visibility(codespace_name, port, 'private', token, tunnel_props)
    time.sleep(2)
    set_port_visibility(codespace_name, port, 'public', token, tunnel_props)

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

    # 4. Determine public URL
    public_url = f'https://{codespace_name}-{port}.app.github.dev'
    print(f'Making port {port} public on Codespace: {codespace_name}')

    # 5. Retry loop: each iteration gets fresh tunnel props, registers port,
    #    toggles visibility, and verifies the endpoint. This handles tunnel
    #    property rotation and stale relay connections.
    total_timeout = 300
    print(f'Entering retry loop (timeout={total_timeout}s) to make {public_url} accessible...')
    deadline = time.time() + total_timeout

    while time.time() < deadline:
        if finalize_port_public(public_url, codespace_name, port, token):
            print(f'Port {port} is now publicly accessible')
            print(f'URL: {public_url}')
            sys.exit(0)

        remaining = int(deadline - time.time())
        if remaining > 0:
            print(f'Retry failed, retrying in 5s ({remaining}s remaining)...')
            time.sleep(5)

    print(f'[error] Failed to make port {port} publicly accessible after {total_timeout}s',
          file=sys.stderr)
    print(f'[error] Try toggling visibility manually:', file=sys.stderr)
    print(f'  gh codespace ports visibility {port}:private --codespace {codespace_name}')
    print(f'  gh codespace ports visibility {port}:public --codespace {codespace_name}')
    sys.exit(1)


if __name__ == '__main__':
    main()