#!/bin/bash
# Creates a UTM VM with QEMU/QCOW2 backend for Ubuntu 26.04 cloud image.
# Disk resize is done via UTM GUI (prompted before VM start).

set -euo pipefail

VM_NAME="container-workspace-utm-vm"
CONTAINER_WORKSPACE_DIR="/Users/ericweber/Desktop/Eric/Projects/container-workspace"
IMAGE_PATH="${CONTAINER_WORKSPACE_DIR}/utm-vm/ubuntu-26.04-server-cloudimg-arm64.img"
GUEST_MOUNT_PATH="/mnt/shared"

VM_MEMORY_GB=16
VM_CPU_COUNT=8
VM_DISK_SIZE_GB=16
VM_MEMORY_MIB=$((VM_MEMORY_GB * 1024))

UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
UTM_DOCS_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# --- Workspace root (VM-specific) ---
VM_ROOT="${CONTAINER_WORKSPACE_DIR}/utm-vm/${VM_NAME}"
SSH_KEY_DIR="${VM_ROOT}/ssh-keys"
SSH_KEY_FILE="${SSH_KEY_DIR}/id_ed25519"
mkdir -p "$SSH_KEY_DIR"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "🔐 Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "${VM_NAME}"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")

# --- Password ---
RANDOM_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/" || true)
PASSWORDS_FILE="${VM_ROOT}/.password"
echo "$RANDOM_PASSWORD" > "$PASSWORDS_FILE" 2>/dev/null || echo "$RANDOM_PASSWORD"
chmod 600 "$PASSWORDS_FILE" 2>/dev/null || true

# --- Cloud-init config drive ---
CLOUD_INIT_DIR="${VM_ROOT}/cloud-init"
CONFIG_DRIVE_DIR="${CLOUD_INIT_DIR}/cidata"
rm -rf "$CONFIG_DRIVE_DIR"
mkdir -p "$CONFIG_DRIVE_DIR"

# --- Home directory ---
HOME_DIR="${VM_ROOT}/home"
mkdir -p "$HOME_DIR/workspace"

# --- Docker data directory (bind-mounted to /var/lib/docker in cloud-init) ---
mkdir -p "${HOME_DIR}/.docker-data"

# --- Cloud-init user-data configuration ---
# Uses #cloud-config (NoCloud datasource via cidata ISO) for first-boot
# provisioning of the Ubuntu 26.04 cloud image.
cat > "${CONFIG_DRIVE_DIR}/user-data" << 'USERDATA_END'
#cloud-config
hostname: container-workspace-vm
manage_etc_hosts: true
disable_root: true

package_update: true

packages:
  - qemu-guest-agent
  - docker.io
  - python3-pip
  - curl
  - wget
  - net-tools
  - cloud-guest-utils

# mounts: 9p VirtFS share + bind mounts from shared directory.
# Runs in the init stage (before groups/users), so ssh_authorized_keys
# in the users section below persist on the shared host directory.
mounts:
  - [share, /mnt/shared, 9p, trans=virtio,version=9p2000.L,rw,_netdev,nofail,x-systemd.device-timeout=10s, 0, 0]
  - [/mnt/shared, {{CONTAINER_WORKSPACE_DIR}}, none, bind,_netdev,nofail,x-systemd.requires=/mnt/shared,x-systemd.device-timeout=10s, 0, 0]
  - [/mnt/shared/utm-vm/container-workspace-utm-vm/home, /home/{{USER}}, none, bind,_netdev,nofail,x-systemd.requires=/mnt/shared,x-systemd.device-timeout=10s, 0, 0]
  - [/mnt/shared/workspace, /home/{{USER}}/workspace, none, bind,_netdev,nofail,x-systemd.requires=/mnt/shared,x-systemd.device-timeout=10s, 0, 0]

write_files:
  - path: /etc/docker/daemon.json
    content: |
      {
        "data-root": "/home/{{USER}}/.docker-data",
        "hosts": ["unix:///var/run/docker.sock", "tcp://127.0.0.1:2375"]
      }
  - path: /etc/systemd/system/docker.service.d/docker.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=/usr/bin/dockerd --containerd=/run/containerd/containerd.sock

# Pre-create docker group so users module can add {{USER}}
groups:
  - docker

users:
  - name: {{USER}}
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    groups: docker
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - {{SSH_PUBLIC_KEY}}

# Password management via chpasswd (recommended approach — more portable
# than hashed_passwd in the users module, handles distribution differences).
chpasswd:
  expire: false
  users:
    - name: {{USER}}
      password: {{PASSWORD}}

runcmd:
  - systemctl enable --now qemu-guest-agent
final_message: "Cloud-init configuration complete for container-workspace-vm"
USERDATA_END

sed -i '' "s|{{CONTAINER_WORKSPACE_DIR}}|${CONTAINER_WORKSPACE_DIR}|g" "${CONFIG_DRIVE_DIR}/user-data"
sed -i '' "s|{{SSH_PUBLIC_KEY}}|${SSH_PUBLIC_KEY}|g" "${CONFIG_DRIVE_DIR}/user-data"
sed -i '' "s|{{PASSWORD}}|${RANDOM_PASSWORD}|g" "${CONFIG_DRIVE_DIR}/user-data"
sed -i '' "s|{{USER}}|${USER}|g" "${CONFIG_DRIVE_DIR}/user-data"

cat > "${CONFIG_DRIVE_DIR}/meta-data" << EOF
instance-id: iid-${VM_NAME}
local-hostname: container-workspace-vm
EOF
touch "${CONFIG_DRIVE_DIR}/network-data"

# Create config drive ISO with "cidata" volume label
echo "📦 Creating config drive..."

CONFIG_DRIVE_ISO="${UTM_DOCS_DIR}/${VM_NAME}.iso"
rm -f "$CONFIG_DRIVE_ISO"
# hdiutil needs a directory named "cidata" so the ISO volume label is correct
hdiutil makehybrid -iso -joliet -o "$CONFIG_DRIVE_ISO" "${CONFIG_DRIVE_DIR}" 2>&1

# --- Cloud image into UTM sandbox ---
if [[ "$IMAGE_PATH" != "$UTM_DOCS_DIR"* ]]; then
    echo "⚠️  Cloud image outside sandbox. Copying..."
    cp "$IMAGE_PATH" "${UTM_DOCS_DIR}/$(basename "$IMAGE_PATH")"
    IMAGE_PATH="${UTM_DOCS_DIR}/$(basename "$IMAGE_PATH")"
fi

VM_BUNDLE_DIR="${UTM_DOCS_DIR}/${VM_NAME}.utm"

# Pre-copy config drive ISO into VM bundle's Data directory so UTM can
# reference it as a non-removable drive (ImageName = basename of source).
# Pre-create the directory since the VM bundle doesn't exist yet.
mkdir -p "$VM_BUNDLE_DIR/Data"
CONFIG_DRIVE_IN_BUNDLE="$VM_BUNDLE_DIR/Data/config-drive.iso"
cp "$CONFIG_DRIVE_ISO" "$CONFIG_DRIVE_IN_BUNDLE"

# --- Clean up any existing VM ---
"$UTMCTL" delete "$VM_NAME" 2>/dev/null || true
pkill UTM 2>/dev/null || true
sleep 3
open -a UTM
sleep 3

# --- Create VM with both drives via single osascript command ---
# Hard disk (non-removable) + CD-ROM config drive (non-removable, SCSI interface).
# Non-removable drives get ImageName derived from source basename, so UTM will
# set ImageName = ubuntu-26.04-server-cloudimg-arm64-2.qcow2 for the disk and
# ImageName = config-drive.iso for the CD-ROM, matching the working PlistBuddy
# approach. No removable:true so the drives are internal/non-removable.
echo "Creating VM via AppleScript..."
osascript -e 'tell application "UTM"' \
          -e "set img to POSIX file \"${IMAGE_PATH}\"" \
          -e "set cfg to POSIX file \"${CONFIG_DRIVE_IN_BUNDLE}\"" \
          -e "make new virtual machine with properties {backend:qemu, configuration:{name:\"${VM_NAME}\", architecture:\"aarch64\", drives:{{source:img}, {source:cfg, interface:SCSI}}, memory:${VM_MEMORY_MIB}, cpu cores:${VM_CPU_COUNT}, hypervisor:true, uefi:true}}" \
          -e 'end tell'

echo "✅ VM created and registered"

if ! "$UTMCTL" list | grep -q "$VM_NAME"; then
    echo "Error: VM not found after creation"
    "$UTMCTL" list
    exit 1
fi

# Wait for VM bundle and config.plist to be written to disk
echo "Waiting for VM bundle to be written..."
for i in $(seq 1 10); do
    if [ -f "${VM_BUNDLE_DIR}/config.plist" ]; then
        echo "✅ VM bundle written"
        break
    fi
    echo "  Waiting for VM bundle ($i/10)..."
    sleep 3
done

if [ ! -f "${VM_BUNDLE_DIR}/config.plist" ]; then
    echo "❌ VM bundle not written after 30 seconds"
    exit 1
fi

# Restart UTM so it re-reads config.plist from disk (UTM caches in memory)
echo "Restarting UTM to apply configuration..."
pkill -f UTM 2>/dev/null || true
sleep 5
open -a UTM
sleep 15

# --- Symlink ---
WORKSPACE_UTM_DIR="${VM_ROOT}/utm"
rm -f "$WORKSPACE_UTM_DIR"
mkdir -p "$(dirname "$WORKSPACE_UTM_DIR")"
ln -s "$VM_BUNDLE_DIR" "$WORKSPACE_UTM_DIR"

echo "🔗 Symlink: $WORKSPACE_UTM_DIR -> $VM_BUNDLE_DIR"

# --- VM info ---
echo ""
echo "📋 VM Configuration:"
echo "  Name: $VM_NAME"
echo "  Bundle: $VM_BUNDLE_DIR"
echo "  Memory: ${VM_MEMORY_GB}GB | CPUs: ${VM_CPU_COUNT} | Disk: ${VM_DISK_SIZE_GB}GB"
echo ""

# --- Prompt for GUI configuration ---
echo "============================================="
echo "📋 MANUAL GUI CONFIGURATION REQUIRED"
echo "============================================="
echo ""
echo "The Ubuntu cloud image has a default virtual disk size of ~2.4GB."
echo "To increase the disk to ${VM_DISK_SIZE_GB}GB:"
echo ""
echo "  1. Open UTM.app"
echo "  2. Right-click on the VM: \"$VM_NAME\""
echo "  3. Select \"Edit\""
echo "  4. Under \"Drives\", select \"VirtIO Drive\" (the main disk)"
echo "  5. Choose \"Resize\" and set the target size to ${VM_DISK_SIZE_GB} GB"
echo "  6. Click \"Resize\", confirm the dialog, and click \"Save\""
echo ""
echo "============================================="
echo "📋 VIRTFS SHARED FOLDER CONFIGURATION"
echo "============================================="
echo ""
echo "Configure VirtFS shares for the container-workspace folder:"
echo ""
echo "  1. In the same VM Edit window, go to the \"Sharing\" tab"
echo "  2. Set \"Directory Share Mode\" to \"VirtFS\""
echo "  3. Add a new share with:"
echo "     - Path: ${CONTAINER_WORKSPACE_DIR}"
echo "     - ReadOnly: unchecked"
echo "  4. Click \"Save\""
echo ""
echo "The cloud-init config will mount this share to /mnt/shared and"
echo "bind-mount sub-paths to /home/${USER} and /home/${USER}/workspace."
echo ""
echo "============================================="
echo ""

read -r -p "Press ENTER after you have resized the disk and configured VirtFS sharing, then clicked 'Save' in UTM... "
echo ""
echo "Starting VM..."
"$UTMCTL" start "$VM_NAME"

# --- Wait for VM to start ---
echo "Waiting for VM to boot..."
for i in {1..60}; do
    if "$UTMCTL" status "$VM_NAME" | grep -q "started"; then
        echo "✅ VM is started"
        break
    fi
    echo "  Still booting... ($i/60)"
    sleep 5
done

# --- Wait for SSH ---
echo "Waiting for SSH to be available..."

for i in {1..60}; do
    VM_IP=$("$UTMCTL" ip-address "$VM_NAME" 2>/dev/null | head -1 || echo "")
    if [ -z "$VM_IP" ]; then
        echo "  Waiting for IP address... ($i/60)"
        sleep 5
        continue
    fi
    sleep 5
    set +e
    SSH_OUTPUT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_FILE" "${USER}@${VM_IP}" "exit" 2>&1)
    SSH_RC=$?
    set -e
    if [ $SSH_RC -eq 0 ]; then
        echo "✅ SSH ready at $VM_IP"
        echo "Checking cloud-init status..."
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_FILE" "${USER}@${VM_IP}" \
            "tail -20 /var/log/cloud-init-output.log 2>/dev/null; cloud-init status 2>/dev/null || true" 2>/dev/null || true
        break
    fi
    echo "  Waiting for SSH... ($i/60)"
done

# --- Final output ---
echo ""
echo "✅ VM setup complete!"
echo "VM Name: $VM_NAME"
echo "Bundle: $VM_BUNDLE_DIR"
echo "Symlink: $WORKSPACE_UTM_DIR"
echo "Shared directory: $CONTAINER_WORKSPACE_DIR -> $GUEST_MOUNT_PATH"
echo ""
echo "🔐 SSH key: $SSH_KEY_FILE"
echo "🔐 Password: $RANDOM_PASSWORD (saved to $PASSWORDS_FILE)"
if [ -n "$VM_IP" ]; then
    echo "🔗 ssh -i \"${SSH_KEY_FILE}\" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER}@${VM_IP}"
fi
echo ""
echo "📝 Commands:"
echo "  Start VM:   $UTMCTL start \"$VM_NAME\""
echo "  Exec cmd:   $UTMCTL exec \"$VM_NAME\" -- <command>"
echo "  Get IP:     $UTMCTL ip-address \"$VM_NAME\""
