# Traefik Reverse Proxy for Hermes WebUI

A Traefik v3 reverse proxy that forwards traffic from port 8780 to the Hermes WebUI running on port
8787 inside the devcontainer. Includes a landing page shown when the WebUI is not yet ready.

## Architecture

```
Browser -> Codespaces Port Forward (8780) -> Traefik (Docker, port 8780) -> Hermes WebUI (devcontainer, port 8787)
                                            |
                                            +-> Landing page (Docker, port 8081) [when WebUI is down]
```

The Hermes WebUI runs directly inside the devcontainer (not as a Docker container). Traefik runs in
a Docker container and proxies to `172.17.0.1:8787` (the Docker bridge gateway -> devcontainer
host).

## Files

| File                 | Purpose                                                         |
| -------------------- | --------------------------------------------------------------- |
| `docker-compose.yml` | Traefik service definition + landing page service               |
| `traefik.yml`        | Static configuration (entrypoints, providers, logging)          |
| `dynamic/webui.yml`  | Dynamic configuration (router, service, error pages middleware) |
| `static/index.html`  | Landing page HTML shown when WebUI is not ready                 |
| `README.md`          | This file                                                       |

## How the Landing Page Works

Traefik's `errors` middleware intercepts HTTP 502/503/504 responses from the backend (which occur
when the WebUI is starting up or has crashed) and serves a custom landing page from the Caddy-based
`landing` service instead. The landing page:

- Shows the Hermes logo and a "WebUI starting up..." message
- Has a spinner animation
- Auto-refreshes every 10 seconds to check if the WebUI is ready

When the WebUI is back up, Traefik automatically routes requests through normally again (no restart
needed for Traefik).

## Usage

### Start the proxy

```bash
docker compose -f traefik/docker-compose.yml up -d
```

### Check status

```bash
docker compose -f traefik/docker-compose.yml ps
docker compose -f traefik/docker-compose.yml logs --tail 20
```

### Stop the proxy

```bash
docker compose -f traefik/docker-compose.yml down
```

### Follow logs

```bash
docker compose -f traefik/docker-compose.yml logs -f
```

## Port Mapping

| Source         | Destination               | Description                                     |
| -------------- | ------------------------- | ----------------------------------------------- |
| 8780 (exposed) | 8780 (Traefik entrypoint) | Public port for the proxy                       |
| 8787 (host)    | —                         | Direct WebUI access (still works independently) |

## Configuration Details

### Static config (`traefik.yml`)

- Entrypoint on port 8780
- File provider watching `/etc/traefik/dynamic/` for changes
- JSON logging to stdout

### Dynamic config (`dynamic/webui.yml`)

- Router: `PathPrefix("/")` — catch-all route matching all paths
- Error middleware: intercepts 502/503/504 responses
- Service: `http://172.17.0.1:8787` — Docker bridge gateway to devcontainer
- Health check: probes `/health` every 5s using GET method
- Landing service: `http://landing:8081` — fallback page when backend is down

### Auto-restart

The Traefik and landing containers are configured with `restart: unless-stopped` so they
automatically restart if the Docker daemon restarts.
