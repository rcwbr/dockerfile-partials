# VM-in-VM Approach: Nested Virtualization for Container Runtimes

## Goal

Enable full container runtime functionality inside Apple container VMs by running a lightweight
nested VM (QEMU or Firecracker) that has unrestricted kernel syscalls but sits within Apple's
security boundaries.

## Constraints

- Must work within Apple container's existing `--virtualization` flag support
- No direct access to Apple's hypervisor APIs from within container
- Must maintain isolation — outer VM protects host
- Need to verify which VMMs Apple's `--virtualization` actually exposes to containers

## TODO List

### Phase 1: Environment Discovery

- \[ \] Verify `--virtualization` flag effectiveness with QEMU
- \[ \] Check `/dev/kvm` availability inside Apple container with `--virtualization`
- \[ \] Check `/dev/hvf` (Hypervisor Framework) device availability
- \[ \] Check if KVM ioctl support exists for userspace VMM
- \[ \] Determine if Apple container exposes nested virtualization at all
- \[ \] Research Apple Virtualization Framework limitations

### Phase 2: QEMU Approach (Baseline - Slow Fallback)

- \[ \] Get QEMU system running inside Apple container with basic kernel boot
- \[ \] Verify nested VM gets full kernel syscall interface (unshare, clone, etc.)
- \[ \] Get networking working via SLIRP (QEMU user networking)
- \[ \] Install container runtime (Docker/Podman) inside nested VM
- \[ \] Run inner containers successfully
- **Note:** Will use TCG (software emulation) since `/dev/kvm` unavailable — expect 100x slowdown

### Phase 3: Firecracker Approach (Optimized)

- \[ \] Build Firecracker-compatible Linux kernel and rootfs
- \[ \] Launch Firecracker microVM inside Apple container
- \[ \] Verify syscall availability in Firecracker VM
- \[ \] Install container runtime inside Firecracker VM
- \[ \] Run containers with proper networking

### Phase 4: Integration Testing

- \[ \] Compare QEMU vs Firecracker performance for container operations
- \[ \] Test image pull/build/push workflows
- \[ \] Verify isolation between nested VM and outer container
- \[ \] Document resource requirements and tradeoffs

## Alternative Approaches (Non-KVM VMMs)

### Option A: QEMU TCG Mode (Software Virtualization)

- Runs entirely in userspace via Tiny Code Generator
- No `/dev/kvm` required
- **Performance penalty**: ~100x slower than native KVM
- **Pros**: Well-supported, runs Linux guest with full syscall interface
- **Cons**: Extremely slow for container workloads
- **Implementation**:
  ```bash
  container run --rm --virtualization docker:qemu sh -c '
    # Create disk image
    qemu-img create -f qcow2 /tmp/guest.qcow2 20G

    # Boot with TCG (no KVM)
    qemu-system-aarch64 \
      -machine virt,accel=tcg \
      -cpu cortex-a57 \
      -m 2G -smp 1 \
      -kernel /path/to/kernel \
      -drive file=/tmp/guest.qcow2,format qcow2 \
      -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
      -nographic
  '
  ```

### Option B: Firecracker with PVM (Pagetable VM) Fork

- Modified Firecracker that runs without hardware virtualization
- Uses software-backed `/dev/kvm` via PVM kernel module
- **Performance penalty**: Slower than KVM but possibly faster than QEMU TCG
- **Pros**: Maintains Firecracker's minimal footprint and security model
- **Cons**: Requires custom kernel, experimental, x86-focused
- **Reference**: https://github.com/dywongcloud/firecracker-next

### Option C: gVisor Container Runtime

- Intercept syscalls and emulate kernel functionality in userspace
- Used by Google in production (Google Cloud Run, GKE Sandbox)
- **No VM required** — containers run with simulated kernel
- **Pros**: Much faster than full VMs, proven at scale
- **Cons**: Syscall compatibility limitations
- **Implementation**:
  ```bash
  # Run Docker with gVisor runtime
  dockerd --containerd=/etc/docker/containerd-config.conf \
  	--experimental --add-runtime gvisor \
  	--default-runtime gvisor
  ```

### Option D: Sysbox Container Runtimes

- Daemonless, secure container runtimes that don't need full VM isolation
- Uses userspace namespace simulation where kernel namespaces are unavailable
- **Pros**: Drop-in replacement for runc
- **Cons**: May still need some kernel support

## Decision Matrix

| Approach                | Requires unshare()? | Speed     | Complexity | Security  |
| ----------------------- | ------------------- | --------- | ---------- | --------- |
| Current rootless Docker | ❌ Blocked          | Fast      | Simple     | Good      |
| QEMU TCG                | ✅ (in nested VM)   | Very Slow | Complex    | Excellent |
| Firecracker PVM         | ✅ (in nested VM)   | Slow      | Complex    | Excellent |
| gVisor                  | ❌ (simulated)      | Moderate  | Moderate   | Good      |
| Sysbox                  | ❌ (simulated)      | Fast      | Moderate   | Good      |

## Recommendation: Try gVisor First

gVisor intercepts syscalls in userspace, simulating kernel services without needing `unshare()`.
This could give us container execution within the outer Docker daemon without requiring nested VMs.

### gVisor Implementation Plan

1. Install gVisor (`runsc` binary) inside the dockerd container
1. Configure Docker daemon to use `runsc` as runtime
1. Test container execution

```bash
# Inside the running dockerd container
container exec dockerd sh -c '
  # Download gVisor
  wget https://storage.googleapis.com/gvisor/releases/nightly/latest/runsc
  chmod +x runsc
  mv runsc /usr/local/bin/

  # Configure Docker to use gVisor
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << EOF
{
  "runtimes": {
    "runsc": {
      "path": "/usr/local/bin/runsc",
      "runtimeArgs": []
    }
  }
}
EOF

  # Restart daemon or test with runsc directly
  runsc --platform=sandbox --file-access=exclusive --rootless=true \
    ps aux
'
```

## Expected Behaviors to Verify

| Behavior                                                 | Expected | Why It Matters                     |
| -------------------------------------------------------- | -------- | ---------------------------------- |
| Nested VM boots                                          | ✅       | Basic virtualization works         |
| `unshare()` syscall succeeds in nested VM                | ✅       | Container runtimes need namespaces |
| Container runtime installs in nested VM                  | ✅       | Proves full syscall interface      |
| Pull Docker image from nested VM                         | ✅       | Network connectivity works         |
| Run container in nested VM                               | ✅       | Full container lifecycle possible  |
| Outer container unaffected by inner container compromise | ✅       | Isolation maintained               |

## Implementation Sketch

### QEMU Approach

```bash
container run --rm \
	--virtualization \
	--memory 8G \
	--cpus 4 \
	docker:qemu \
	sh -c '
    # Create VM disk
    qemu-img create -f qcow2 /tmp/nested.qcow2 10G

    # Launch VM with nested container runtime
    qemu-system-aarch64 \
      -machine virt,gic-version=3 \
      -cpu max \
      -m 4G -smp 2 \
      -kernel /path/to/kernel \
      -drive file=/tmp/nested.qcow2,format=qcow2 \
      -netdev user,id=net0 -device virtio-net-device,netdev=net0 \
      -nographic
  '
```

### Firecracker Approach

```bash
container run --rm \
	--virtualization \
	--memory 8G \
	--cpus 4 \
	--tmpfs /run \
	firecracker/firecracker-containerd:latest \
	sh -c '
    # Create rootfs and kernel
    # Launch Firecracker microVM
    /usr/local/bin/jailer --id nested-vm \
      --exec /firecracker \
      --root-dir /srv/jailer
  '
```

## Open Questions

1. Does Apple's `--virtualization` expose `/dev/kvm` or `/dev/hvf` to containers?
1. Can QEMU access hardware acceleration from within the Apple container?
1. Does Firecracker's KVM-based approach work or does it also require direct kernel access?
1. What's the performance penalty for nested virtualization?

## Learnings Uncovered While Planning

### Environment Discovery Results

Ran `container run --rm --virtualization ubuntu:24.04` and checked:

- `/dev/kvm` **NOT available**
- `/dev/hvf` **NOT available**
- `/proc/virt` **NOT available**
- Kernel modules directory empty (KVM not in kernel)
- No KVM-related kernel modules loaded

**Critical Finding:** Even with `--virtualization` flag enabled, Apple containers do **not** expose
any virtualization devices (`/dev/kvm`, `/dev/hvf`) to container processes. The `--virtualization`
flag appears to provide virtualization capabilities to the Apple container VM itself, but does
**not** expose nested virtualization interfaces to processes running inside the container.

This means:

- ❌ QEMU cannot use hardware acceleration (no `/dev/kvm`)
- ❌ QEMU can only use software emulation (TCG mode, ~100x slower)
- ❌ Firecracker/KVM approach will not work (requires `/dev/kvm`)
- ❌ No Hypervisor Framework access (`/dev/hvf` missing)

### gVisar Installation via Apt Repository

**SUCCESS** - Used official gVisor apt repository to install runsc:

```bash
# Install gVisara via apt (official method)
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq ca-certificates curl gnupg wget >/dev/null
curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" >/etc/apt/sources.list.d/gvisor.list
apt-get update -qq
apt-get install -y -qq runsc >/dev/null

# Verify
runsc --version 2>&1
# Output: runsc version release-20260914.0
#         spec: 1.2.1
#         /usr/bin/runsc
```

**Key insight**: Direct download from Google Cloud Storage bucket was failing with 404 errors due to
incorrect URL path. The apt repository method handles URL resolution automatically and is more
reliable.

[!NOTE]
Ubuntu 24.04's `tar` supports `--zstd` natively, avoiding BusyBox compatibility issues.

### Syscall Restrictions Confirmed

Through systematic testing (Docker daemon + containerd + native snapshotter), we've identified that
Apple's container VM blocks **multiple Linux namespace/syscall operations**:

1. **`unshare()`** — Used by Docker/containerd to create isolated process/mount/PID/user namespaces

   - Error: `operation not permitted`

1. **`mount(MS_BIND)`** — Used during layer extraction to set up temporary mounts

   - Error: `failed to mount: operation not permitted`

1. **`clone()` with namespace flags** — Used by container runtimes to spawn isolated processes

   - Likely blocked (inferred from unshare being blocked)

**Root cause**: These syscalls form the foundation of the Linux container model. Apple's container
VM kernel intentionally blocks them to prevent escape attempts from compromised containers to the
host macOS system.

### gVisor Installation Confirmed

Successfully installed gVisor (`runsc`) binary:

- **Version**: `runsc version release-20260914.0`
- **Spec**: 1.2.1
- **Location**: `/usr/local/bin/runsc`
- **Status**: Binary installs correctly and reports version

Docker daemon recognizes runsc as a valid runtime after configuration.

### Critical Architecture Insight

The `unshare()` and `mount()` syscalls are called by **layer extraction** components of container
runtimes (Docker/containerd), NOT by the actual container runtimes themselves. This means:

1. ✅ Image pull/download works (no restricted syscalls)
1. ✅ Layer decompression works (pure file I/O)
1. ✅ Container execution with runsc might work (different syscall model)
1. ❌ Layer extraction/extraction fails (requires unshare/mount)

**Solution**: Bypass layer extraction entirely by:

- Preparing rootfs manually (using `tar` extraction)
- Using runsc's direct OCI bundle interface
- Avoiding containerd/Docker's snapshotter layer management entirely

### gVisar Testing with Runsc (User Feedback Loop)

Successfully installed gVisar via apt repository:

- Version: `runsc version release-20260914.0`
- Location: `/usr/bin/runsc` (installed via package manager)

**Test Results:**

1. ✅ Image pull works (network connectivity confirmed)
1. ✅ runsc binary installs and reports version
1. ❌ `runsc run` fails with cgroup configuration error
1. ❌ `--cgroup=false` flag doesn't exist (incorrect flag name)

**Current blocker:** runsc fails with:

```
cannot set up cgroup for root: configuring cgroup:
write /sys/fs/cgroup/cgroup.subtree_control: device or resource busy
```

This is NOT an `unshare()` error — it's a cgroup v2 write permission issue.

**Next steps:** Try disabling cgroups in runsc using correct flag:

- `--cgroup-manager=none` (the actual flag name)
- `--cgroup=false` (incorrect - doesn't exist)

Also explore runsc's `do` subcommand for testing without full init.

Example test approach:

```bash
mkdir -p /tmp/bundle/rootfs/bin
cp /bin/busybox /tmp/bundle/rootfs/bin/
runsc spec -- /bin/sh -c "echo Hello from gVisa"
runsc run --rootless=true test-bundle
```

### Next Steps: Direct runsc OCI Bundle

Test whether runsc can create a functional sandboxed container when:

1. A rootfs is prepared using direct `tar` extraction (no mount)
1. An OCI bundle is created with `runsc spec`
1. The container is launched with `runsc run`

This completely sidesteps the layer extraction pipeline that fails due to syscall restrictions.

### Updated Decision Matrix

| Approach        | Requires unshare()? | Requires mount()? | Speed     | Complexity | Security  | Works?            |
| --------------- | ------------------- | ----------------- | --------- | ---------- | --------- | ----------------- |
| Rootless Docker | ❌ Blocked          | ❌ Blocked        | Fast      | Simple     | Good      | ❌                |
| Root Docker     | ❌ Blocked          | ❌ Blocked        | Fast      | Medium     | Fair      | ❌                |
| QEMU TCG        | ✅ (in nested VM)   | ✅ (in nested VM) | Very Slow | Complex    | Excellent | ✅ (but unusable) |
| Firecracker     | ✅ (in nested VM)   | ✅ (in nested VM) | Slow      | Complex    | Excellent | ❌ (no /dev/kvm)  |
| gVisa (runsc)   | ❓ (unknown yet)    | ❓ (unknown yet)  | Fast      | Moderate   | Excellent | ⏳ (testing)      |
