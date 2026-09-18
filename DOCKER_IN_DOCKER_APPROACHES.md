# Isolated Docker-in-Docker via Container Run — Final Approach

## Environment

- **Host:** macOS 26, Apple Silicon arm64
- **Apple container CLI:** v1.1.0
- **Image:** `docker:dind-rootless` (Alpine-based, Docker 29.8.1)

## Key Discovery

The `container run` command supports `--virtualization` flag:

```
--virtualization: Expose virtualization capabilities to the container (requires host and guest support)
```

Combined with `--cap-add` (which the user wants to avoid), this might enable the nested
containerization we need.

However, the user explicitly wants to avoid `--privileged` and `--cap-add`. Let me check if
`--virtualization` alone is sufficient for Docker daemon's `unshare()` requirement.

## Current Working State

- Docker daemon starts as root (UID 0) with `--user root` ✅
- Image pulling works (outer container network) ✅
- `--storage-driver=vfs` works ✅
- `--iptables=false --bridge=none` works ✅
- **BUT:** `unshare: operation not permitted` when running inner containers ❌

## Next Attempt: --virtualization flag

```bash
container rm -f dockerd 2>/dev/null
true

container run -d --rm --name dockerd \
	--memory 4G --cpus 2 --tmpfs /run \
	--user root \
	--virtualization \
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

container logs dockerd 2>&1 | tail -20
container exec dockerd docker info | grep -E "Server Version|Storage|rootless"

# Test inner container
container exec dockerd docker run --rm alpine:3.20 echo "Inner container works!"
```

## Alternative: Use --init-image to pre-create TUN device

If `--virtualization` doesn't enable `unshare()`, we can try using a custom init image that sets up
`/dev/net/tun` before the main container starts.

## Alternative: Use `--cap-add sys_admin` (NOT PREFERRED - user wants to avoid)

The `unshare()` syscall requires `CAP_SYS_ADMIN`. We could add it:

```
--cap-add SYS_ADMIN
```

But this violates the user's constraint of no `--cap-add`.

## Fallback: Containerd with different runtime

If Docker daemon fundamentally requires namespaces that Apple's container VM blocks, we could:

1. Run containerd directly (not dockerd)
1. Use containerd's `native` snapshotter (no overlay)
1. Configure containerd to not require namespace creation

But this is a major departure from the Docker goal.
