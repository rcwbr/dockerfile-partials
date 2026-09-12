# Container/Host-System/Launch Process Structure

## Components

1. **Codespace host VM** — Azure VM that provisions and runs the devcontainer
2. **Devcontainer container** — Docker container (managed by devcontainer CLI) running inside the
   host VM
3. **Docker daemon** — Runs on the Codespace host VM, not inside the devcontainer container

## Filesystem Isolation

### What Works

- **Image layers** — Files `COPY`ed by the Dockerfile during image build ARE visible to
  Docker containers. Docker reads from its own image storage, not the devcontainer's
  overlay filesystem.
- **`/workspaces/` bind mounts** — Files written from the devcontainer shell (e.g., `cp`, `tee`)
  to `/workspaces/` ARE visible to Docker bind mounts on the host VM. The `/workspaces/` path
  is a shared bind mount between the devcontainer container and the host VM.
- **`/var/run/docker.sock`** — Mounted into the devcontainer, giving access to the host VM's
  Docker daemon.

### What Doesn't Work

- **`/opt/devcontainers/` runtime writes** — This path is baked into the devcontainer image at
  build time. Runtime writes go to the devcontainer's overlay filesystem, invisible to Docker.
- **`/tmp/` and `/home/codespace/`** — Each has its own filesystem view; writes by the
  devcontainer are not visible to Docker bind mounts.
- **`/var/lib/docker/codespacemount/`** — Does NOT exist on Codespace host VMs.

### Key Insight

The Docker daemon runs **on the host VM**, not inside the devcontainer container. While
`/workspaces/` is a shared path, the most **reliable** approach for passing configuration
files to Docker containers is to **bake them into a Docker image layer**. This avoids all
shared-filesystem concerns by writing files inside a container (via `docker exec`) and
committing the result as an image.

## Docker Daemon Access

- The Docker daemon on the host VM is accessible from the devcontainer via `/var/run/docker.sock`
  (mounted bind)
- All `docker` commands run inside the devcontainer target the host VM's Docker daemon
- Volumes and bind mounts are resolved by the host VM's filesystem, not the devcontainer's

## Image-Baking Pattern (Primary Solution)

Since config files at `/opt/devcontainers/` are invisible to Docker at runtime, bake them
into a Docker image:

1. Start a temporary container from the base image (`docker run -d --name builder --entrypoint sleep`)
2. Write config files into the container's filesystem (via `docker exec` + base64)
3. Commit the container as a new image (`docker commit builder my-image`)
4. Run the container from the committed image (no bind mounts needed)
5. Clean up the temp container

**Critical:** `docker commit` preserves the overridden `--entrypoint sleep`, so the
committed image must be run with `--entrypoint /entrypoint.sh` (or the original entrypoint).
