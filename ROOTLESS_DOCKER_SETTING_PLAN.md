# Isolated Rootless Docker in Apple container — Progress Summary

## Goal

Run a fully-isolated Docker daemon (`dockerd`) inside Apple's `container` CLI on macOS 26 (Apple
Silicon), **without `--privileged` or `--cap-add`**. The daemon runs in **rootless mode** (user
namespaces + slirp4netns) for isolation.

## Environment

- **Host:** macOS 26, Apple Silicon arm64
- **Apple container CLI:** v1.1.0
- **User:** `ericweber`
- **`/dev/net/tun` exists** at `crw------- 1 root root` inside the VM

## Approaches Tried

### Attempt 1: `container run --user rootless docker:dind-rootless` (no device mapping)

**Result:** Rootless entrypoint activated, but slirp4netns fails because rootless user can't open
`/dev/net/tun`.

```
[rootlesskit:parent] error: failed to setup network: setting up tap tap0:
  executing [[nsenter ... ip tuntap add name tap0 mode tap] ...]]: exit status 1
```

**Root cause:** `/dev/net/tun` permissions `crw------- 1 root root` — rootless user can't access it.

### Attempt 2: `--device /dev/net/tun:/dev/net/tun`

**Result:** Failed — Apple's `container run` doesn't support `--device` flag ("Unknown option
'--device'").

### Attempt 3: `--mount type=bind,source=/dev/net/tun,target=/dev/net/tun`

**Result:** Failed — `/dev/net/tun` doesn't exist on the macOS host filesystem. The path only exists
inside the Linux container VM.

### Attempt 4: `--tmpfs /dev`

**Result:** Failed — replacing `/dev` breaks essential device nodes needed by the container runtime.

### Attempt 5: `container build` with custom Dockerfile

**Result:** Failed — "Rosetta is not installed" error from `container build`'s buildkit.

### Attempt 6: `container run` with `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=none` (SUCCESS)

**Result:** ✅ **Rootless Docker daemon starts successfully!** All security properties achieved.

```bash
container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user rootless \
	-e DOCKERD_ROOTLESS_ROOTLESSKIT_NET=none \
	-e DOCKER_HOST=unix:///run/user/1000/docker.sock \
	docker:dind-rootless
```

**Output from `docker info`:**

```
Server Version: 29.8.1
Storage Driver: overlayfs
Security Options:
  seccomp
    Profile: builtin
  rootless                    ← ROOTLESS MODE ACTIVE
  cgroupns
Network: bridge host ipvlan macvlan null overlay
```

### Attempt 7: `container machine` with Alpine

**Result:** Packages installed successfully, `runuser` works, but same `/dev/net/tun` permission
limitation would apply. Left as a backup approach.

## Current Status

### Working (✅)

- Rootless Docker daemon starts with no `--privileged` or `--cap-add`
- User namespace isolation active (rootless mode confirmed)
- `docker info` works, daemon responsive
- Container VM provides natural network isolation from macOS host

### Limitation (⚠️)

- Inner containers have **loopback-only networking** (no slirp4netns)
- Cannot pull images from registries (no network in inner containers)
- Cannot expose ports from inner containers

## Networking Next Steps

### Option A: Use `--publish-socket` for host-to-daemon connection

Expose the rootless Docker daemon's API socket to the macOS host:

```bash
container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user rootless \
	-e DOCKERD_ROOTLESS_ROOTLESSKIT_NET=none \
	-e DOCKER_HOST=unix:///run/user/1000/docker.sock \
	--publish-socket ~/docker.sock:/run/user/1000/docker.sock \
	docker:dind-rootless

sleep 5

# Interact from host
DOCKER_HOST=unix://$HOME/docker.sock docker info
```

**Limitation:** Inner containers still have loopback-only networking. The daemon itself has network
access for API calls, but inner containers don't inherit it.

### Option B: Pre-cache images for testing

Since we can't pull images in inner containers, manually import a test image:

```bash
container exec dockerd sh -c 'echo -e "FROM scratch\nCMD echo Hello from isolated rootless Docker!" | docker import - hello-test'
container exec dockerd docker run --rm --network=none hello-test
```

This proves the full container lifecycle works (create, run, cleanup) without needing network
access.

### Option C: Switch to `container machine` for persistent VM with device modifications

In a `container machine` (persistent VM), we could:

1. `chmod 666 /dev/net/tun` inside the VM
1. Start rootless Docker with full slirp4netns networking
1. Inner containers get proper network access

Commands:

```bash
# Inside container machine VM
chmod 666 /dev/net/tun
runuser -u ericweber -- sh -c 'XDG_RUNTIME_DIR=/run/user/501 /usr/bin/dockerd-rootless.sh'
```

## Verification Commands

### Daemon health check (✅ Working)

```bash
container exec dockerd docker info
```

### Container lifecycle test (no network needed)

```bash
container exec dockerd sh -c 'echo -e "FROM scratch\nCMD echo Hello from isolated rootless Docker!" | docker import - hello-test'
container exec dockerd docker run --rm --network=none hello-test
```

### Host-to-daemon API access (via published socket)

```bash
# Start with --publish-socket
container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user rootless \
	-e DOCKERD_ROOTLESS_ROOTLESSKIT_NET=none \
	--publish-socket ~/docker.sock:/run/user/1000/docker.sock \
	docker:dind-rootless

# From Mac host
DOCKER_HOST=unix://$HOME/docker.sock docker info
```

## Security Properties (Achieved)

- ✅ **No `--privileged`** on any `container` command
- ✅ **No `--cap-add`** required
- ✅ **Rootless Docker daemon** — runs as non-root user (UID 1000)
- ✅ **User namespaces** — inner containers isolated via UID mapping
- ✅ **TUN device isolation** — `/dev/net/tun` is VM-local, not shared with macOS host
- ✅ **Container VM isolation** — Apple's Virtualization.framework provides micro-VM boundaries

## Files Created

- `/workspaces/dockerfile-partials/ROOTLESS_DOCKER_SETTING_PLAN.md` — This document
- `/workspaces/dockerfile-partials/Dockerfile.isolated-docker` — Unused Dockerfile (container build
  blocked by Rosetta)
