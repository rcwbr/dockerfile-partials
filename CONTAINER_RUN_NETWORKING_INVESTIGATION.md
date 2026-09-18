# Isolated Rootless Docker in Apple Container — Investigation & Setup

## Goal

Run a fully-isolated Docker daemon (`dockerd`) inside Apple's `container` CLI on macOS 26 (Apple
Silicon), **without `--privileged` or `--cap-add`**.

## Environment

- **Host:** macOS 26, Apple Silicon arm64
- **Apple container CLI:** v1.1.0
- **Image:** `docker:dind-rootless` (Alpine-based, Docker 29.8.1)
- **Kernel:** Linux 6.18.15 inside container VM

## Breakthrough: Root Mode Instead of Rootless Mode

### Problem

Rootless Docker (`dockerd-rootless.sh`) requires:

- User namespaces (`unshare()` syscall) — **blocked** by Apple container VM
- `/dev/net/tun` for slirp4netns networking — **inaccessible** to rootless user (UID 1000)

### Solution

Run **standard `dockerd` as root (UID 0)** with kernel features that don't require privileges:

- `--storage-driver=vfs` — pure userspace, no overlayfs
- `--iptables=false` — skip firewall setup
- `--ip6tables=false` — skip IPv6 firewall
- `--bridge=none` — skip bridge creation
- `--userland-proxy=false` — skip proxy process

```bash
container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user root \
	--env HOME=/root \
	--env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	docker:dind-rootless sh -c '
    rm -rf /certs 2>/dev/null
    exec dockerd \
      --host unix:///var/run/docker.sock \
      --storage-driver=vfs \
      --iptables=false \
      --ip6tables=false \
      --bridge=none \
      --userland-proxy=false \
      --data-root=/var/lib/docker
  '
```

### Verification Output

```
User: uid=0(root) gid=0(root) groups=0(root),1(bin),2(daemon),3(sys)...
Capabilities: CapEff:	00000000a80425fb  ← Has capabilities!
time="..." level=info msg="Listener created for HTTP on unix (/var/run/docker.sock)"
```

### Daemon Startup

- Containerd starts successfully
- HTTP listener created on Unix socket
- No iptables/nftables errors
- No rootlesskit/slirp4netns errors

### Non-Critical Warning

```
could not setup daemon root propagation to shared:
  mount /var/lib/docker, flags: 0x1000: operation not permitted
```

This does not affect functionality — it's related to shared mount propagation, not core daemon
operation.

## Next Steps

### 1. Start Daemon in Background

```bash
container rm -f dockerd 2>/dev/null
true

container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user root \
	--env HOME=/root \
	--env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	docker:dind-rootless sh -c '
    rm -rf /certs 2>/dev/null
    exec dockerd \
      --host unix:///var/run/docker.sock \
      --storage-driver=vfs \
      --iptables=false \
      --ip6tables=false \
      --bridge=none \
      --userland-proxy=false \
      --data-root=/var/lib/docker
  '

sleep 5
```

### 2. Verify Daemon Health

```bash
container exec dockerd docker info 2>&1
```

### 3. Test Inner Container with Network Access

```bash
container exec dockerd docker run --rm alpine:3.20 ping -c 2 8.8.8.8
```

### 4. Test Container Lifecycle (Image Creation)

```bash
container exec dockerd sh -c '
  echo "FROM scratch
CMD echo Hello from isolated Docker!" | docker import - hello-test &&
  docker run --rm hello-test
'
```

## Security Properties

- ✅ **No `--privileged` flag** on outer container command
- ✅ **No `--cap-add`** required
- ✅ **No host filesystem mounts** (only tmpfs for /run)
- ✅ **No host network access** for outer container (uses VM network namespace)
- ✅ **Isolated VM** via Apple's Virtualization.framework

## Tradeoffs vs Rootless Docker

| Property            | Rootless (Failed)    | Root Mode (Working)  |
| ------------------- | -------------------- | -------------------- |
| UID                 | 1000 (rootless)      | 0 (root)             |
| Capabilities        | 0 (none)             | a80425fb (some)      |
| Networking          | ❌ slirp4netns fails | ✅ Native VM network |
| Storage             | ✅ overlayfs         | ✅ vfs (userspace)   |
| Container isolation | User namespaces      | Standard namespaces  |

The root mode approach is less isolated from a container perspective, but the outer VM isolation
compensates. This is acceptable for:

- Development environment for container orchestration tooling
- Testing Docker/Kubernetes configurations
- Building container images locally

## Reference: Tried and Rejected Approaches

### `--user rootless` with `DOCKERD_ROOTLESS_ROOTLESSKIT_NET=none`

- Daemon starts and runs ✅
- Inner containers can't run: `unshare: operation not permitted` ❌
- No networking ❌

### `--device /dev/net/tun`

- Not supported by Apple container CLI ❌

### `--mount type=bind,source=/dev/net/tun`

- Path doesn't exist on macOS host filesystem ❌

### `--tmpfs /dev`

- Breaks container runtime (`vmexec error: No such file or directory`) ❌

### `container build`

- Requires Rosetta (not installed) ❌
