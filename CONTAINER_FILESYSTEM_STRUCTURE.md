# Container/Host-System/Launch Process Structure

## Components

1. **Codespace host VM** — Azure VM that provisions and runs the devcontainer
1. **Devcontainer container** — Docker container (managed by devcontainer CLI) running inside the
   host VM
1. **Docker daemon** — Runs on the Codespace host VM, not inside the devcontainer container

## Filesystem Isolation

### What Works

- `/workspaces/` is mounted as a shared volume between the devcontainer container and the host VM's
  Docker daemon — **but ONLY for files present at container image build time** or files from the
  original Codespace repository checkout.
- **Critical discovery**: Writes inside the devcontainer container (via SSH, `tee`, `cp`, etc.) to
  `/workspaces/` are **NOT visible** to Docker containers started by the host VM's Docker daemon.
  The mount appears to be a snapshot, not a live bind mount.
- The Docker daemon's own filesystem operations (e.g., `docker run -v /workspaces:/ws`) see a
  **different view** of `/workspaces/` than the devcontainer container.

### What Doesn't Work

- `/opt/devcontainers/` — baked into the devcontainer Docker image; invisible to the Docker daemon
  on the host VM
- `/var/lib/docker/codespacemount/` — does NOT exist on Codespace host VMs

## Key Insight / Solution

Since the Docker daemon on the host VM cannot see files written inside the devcontainer container
(at `/opt/devcontainers/` or even `/workspaces/`), the only reliable approach is to **bake config
files into a Docker image layer**. This is done by:

1. Starting a temporary container from the base image
1. Writing config files into the container's overlay filesystem (via `docker exec` + base64)
1. Committing the container as a new image (`docker commit`)
1. Running the Traefik container from the committed image (no bind mounts needed)

## Docker Daemon Access

- The Docker daemon on the host VM is accessible from the devcontainer via `/var/run/docker.sock`
  (mounted bind)
- All `docker` commands run inside the devcontainer target the host VM's Docker daemon
- Volumes and bind mounts are resolved by the host VM's filesystem, not the devcontainer's
