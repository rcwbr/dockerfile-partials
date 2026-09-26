#!/bin/bash
# Creates a UTM VM with QEMU/QCOW2 backend for Ubuntu 26.04 cloud image.
# Disk resize is done via UTM GUI (prompted before VM start).

set -euo pipefail

VM_NAME="container-workspace-utm-vm"
CONTAINER_WORKSPACE_DIR="/Users/ericweber/Desktop/Eric/Projects/container-workspace"
IMAGE_PATH="${CONTAINER_WORKSPACE_DIR}/utm-vm/ubuntu-26.04-server-cloudimg-arm64.img"
GUEST_MOUNT_PATH="/mnt/container-workspace"
HOST_SHARE_PATH="${CONTAINER_WORKSPACE_DIR}"

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
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "ubuntu-cloud-vm"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")

# --- Password ---
RANDOM_PASSWORD=$(openssl rand -base64 16 | tr -d "=+/")
PASSWORD_HASH=$(openssl passwd -6 "$RANDOM_PASSWORD")
PASSWORDS_FILE="${VM_ROOT}/.password"
echo "$RANDOM_PASSWORD" > "$PASSWORDS_FILE" 2>/dev/null || echo "$RANDOM_PASSWORD"
chmod 600 "$PASSWORDS_FILE" 2>/dev/null || true

# --- Cloud-init config drive ---
CLOUD_INIT_DIR="${VM_ROOT}/cloud-init"
mkdir -p "$CLOUD_INIT_DIR"

# --- Home directory ---
HOME_DIR="${VM_ROOT}/home"
mkdir -p "$HOME_DIR"

cat > "${CLOUD_INIT_DIR}/user-data" << 'USERDATA_END'
#cloud-config
hostname: container-workspace-vm
manage_etc_hosts: true
ssh_pwauth: true
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
users:
  - name: ubuntu
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - {{SSH_PUBLIC_KEY}}
    passwd: {{PASSWORD_HASH}}
resize_rootfs: true
runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl enable --now docker
  - [cloud-init-per once, growpart, /usr/bin/growpart, /dev/vda, 1]
  - [cloud-init-per once, resize2fs, /dev/vda1]
  - mkdir -p /mnt/shared /home/ubuntu/workspace
  - |
    cat > /etc/fstab << 'FSTAB_EOF'
share           /mnt/shared   9p    trans=virtio,version=9p2000.L,rw,_netdev,nofail,auto   0  0
/mnt/shared/utm-vm/container-workspace-utm-vm/home  /home/ubuntu   none  bind,_netdev,nofail,auto   0  0
/mnt/shared/workspace  /home/ubuntu/workspace  none  bind,_netdev,nofail,auto   0  0
FSTAB_EOF
  - mount -a 2>/dev/null || true
  - echo "=== CLOUD-INIT COMPLETE ===" > /home/ubuntu/setup-complete.txt
  - echo "Timestamp: $(date)" >> /home/ubuntu/setup-complete.txt
  - ip addr show > /home/ubuntu/network-info.txt 2>&1
USERDATA_END

sed -i '' "s|{{SSH_PUBLIC_KEY}}|${SSH_PUBLIC_KEY}|g" "${CLOUD_INIT_DIR}/user-data"
sed -i '' "s|{{PASSWORD_HASH}}|${PASSWORD_HASH}|g" "${CLOUD_INIT_DIR}/user-data"

cat > "${CLOUD_INIT_DIR}/meta-data" << EOF
instance-id: iid-${VM_NAME}
local-hostname: container-workspace-vm
EOF
touch "${CLOUD_INIT_DIR}/network-data"

# Create config drive ISO with "cidata" volume label
echo "📦 Creating config drive..."
CONFIG_DRIVE_DIR="${CLOUD_INIT_DIR}/config-drive"
rm -rf "$CONFIG_DRIVE_DIR"
mkdir -p "$CONFIG_DRIVE_DIR"
cp "${CLOUD_INIT_DIR}/user-data" "${CONFIG_DRIVE_DIR}/user-data"
cp "${CLOUD_INIT_DIR}/meta-data" "${CONFIG_DRIVE_DIR}/meta-data"
touch "${CONFIG_DRIVE_DIR}/network-data"

CONFIG_DRIVE_ISO="${CLOUD_INIT_DIR}/config-drive.iso"
rm -f "$CONFIG_DRIVE_ISO"

# hdiutil needs a directory named "cidata" so the ISO volume label is correct
TEMP_CIDATA_DIR=$(mktemp -d)
cp -R "${CONFIG_DRIVE_DIR}/"* "${TEMP_CIDATA_DIR}/"
mv "${TEMP_CIDATA_DIR}/" "${TEMP_CIDATA_DIR}/cidata" 2>/dev/null || \
    mkdir "${TEMP_CIDATA_DIR}/cidata" && cp -R "${CONFIG_DRIVE_DIR}/"* "${TEMP_CIDATA_DIR}/cidata/"
hdiutil makehybrid -iso -joliet -o "$CONFIG_DRIVE_ISO" "${TEMP_CIDATA_DIR}/cidata" 2>&1
rm -rf "$TEMP_CIDATA_DIR"

CONFIG_DRIVE_SANDBOX="${UTM_DOCS_DIR}/${VM_NAME}.iso"
cp "$CONFIG_DRIVE_ISO" "$CONFIG_DRIVE_SANDBOX"

# --- Cloud image into UTM sandbox ---
if [[ "$IMAGE_PATH" != "$UTM_DOCS_DIR"* ]]; then
    echo "⚠️  Cloud image outside sandbox. Copying..."
    cp "$IMAGE_PATH" "${UTM_DOCS_DIR}/$(basename "$IMAGE_PATH")"
    IMAGE_PATH="${UTM_DOCS_DIR}/$(basename "$IMAGE_PATH")"
fi

# --- Clean up any existing VM ---
"$UTMCTL" delete "$VM_NAME" 2>/dev/null || true
pkill UTM 2>/dev/null || true
sleep 3
open -a UTM
sleep 3

# --- Create VM via AppleScript ---
echo "Creating VM via AppleScript..."
osascript -e 'tell application "UTM"' \
          -e "set img to POSIX file \"${IMAGE_PATH}\"" \
          -e "set cfg to POSIX file \"${CONFIG_DRIVE_SANDBOX}\"" \
          -e "make new virtual machine with properties {backend:qemu, configuration:{name:\"${VM_NAME}\", architecture:\"aarch64\", drives:{{source:img}, {removable:true, source:cfg}}, memory:${VM_MEMORY_MIB}, cpu cores:${VM_CPU_COUNT}, hypervisor:true, uefi:true}}" \
          -e 'end tell'

echo "✅ VM created and registered"

if ! "$UTMCTL" list | grep -q "$VM_NAME"; then
    echo "Error: VM not found after creation"
    "$UTMCTL" list
    exit 1
fi

# --- Get VM bundle path ---
VM_BUNDLE_DIR=""
for dir in "${UTM_DOCS_DIR}/${VM_NAME}"*.utm; do
    if [ -d "$dir" ]; then
        VM_BUNDLE_DIR="$dir"
        break
    fi
done

if [ -z "$VM_BUNDLE_DIR" ]; then
    echo "Error: VM bundle directory not found"
    exit 1
fi

# Copy config drive into VM bundle Data directory
cp "$CONFIG_DRIVE_SANDBOX" "${VM_BUNDLE_DIR}/Data/config-drive.iso"

# --- Fix config.plist ---
CONFIG_PLIST="${VM_BUNDLE_DIR}/config.plist"
echo "Configuring VM..."

# Fix CD-ROM drive: set ImageName and interface to SCSI
/usr/libexec/PlistBuddy -c "Set :Drive:1:ImageName config-drive.iso" "$CONFIG_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :Drive:1:ImageName string config-drive.iso" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :Drive:1:Interface SCSI" "$CONFIG_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :Drive:1:Interface string SCSI" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :Drive:1:ImageType CD" "$CONFIG_PLIST" 2>/dev/null || true


# --- Shared directory configuration via QEMU AdditionalArguments ---
# UTM QEMU is sandboxed — host directories copied into VM bundle's Data/ directory
# QEMU:AdditionalArguments injects -fsdev/-device virtio-9p-pci for VirtFS shares

# --- Copy host directories into VM bundle's sandbox (UTM QEMU can't access paths outside Data/) ---
echo "Copying shared directories into VM bundle sandbox..."
SANDBOX_SHARED_DIR="${VM_BUNDLE_DIR}/Data/shared-root"
SANDBOX_HOME_DIR="${VM_BUNDLE_DIR}/Data/shared-home"
rm -rf "$SANDBOX_SHARED_DIR" "$SANDBOX_HOME_DIR"
cp -R "$HOST_SHARE_PATH" "$SANDBOX_SHARED_DIR" 2>/dev/null || true
cp -R "${VM_ROOT}/home" "$SANDBOX_HOME_DIR" 2>/dev/null || true
chown -R $(id -u):$(id -g) "$SANDBOX_SHARED_DIR" "$SANDBOX_HOME_DIR" 2>/dev/null || true

# --- Inject QEMU VirtFS share arguments ---
echo "Injecting QEMU VirtFS share arguments..."
/usr/libexec/PlistBuddy -c "Delete :QEMU:AdditionalArguments" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU dict" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments array" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:0 string -fsdev" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:1 string local,id=fsdev0,path=${SANDBOX_HOME_DIR},security_model=mapped-xattr" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:2 string -device" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:3 string virtio-9p-pci,fsdev=fsdev0,mount_tag=home" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:4 string -fsdev" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:5 string local,id=fsdev1,path=${SANDBOX_SHARED_DIR},security_model=mapped-xattr" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:6 string -device" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :QEMU:AdditionalArguments:7 string virtio-9p-pci,fsdev=fsdev1,mount_tag=share" "$CONFIG_PLIST" 2>/dev/null || true

# Tell UTM to use VirtFS mode for directory sharing
/usr/libexec/PlistBuddy -c "Delete :Sharing" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Sharing dict" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Sharing:DirectoryShareMode string VirtFS" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :Sharing:DirectoryShareReadOnly bool false" "$CONFIG_PLIST" 2>/dev/null || true

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

# --- Prompt for GUI disk resize ---
echo "============================================="
echo "📋 DISK SIZE CONFIGURATION REQUIRED"
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
echo ""

read -r -p "Press ENTER after you have resized the disk and clicked 'Save' in UTM... "
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
    echo "DEBUG: SSH key=$SSH_KEY_FILE, IP=$VM_IP"
    set +e
    SSH_OUTPUT=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_FILE" "ubuntu@${VM_IP}" "exit" 2>&1)
    SSH_RC=$?
    set -e
    echo "DEBUG: SSH exit=$SSH_RC output=$SSH_OUTPUT"
    if [ $SSH_RC -eq 0 ]; then
        echo "✅ SSH ready at $VM_IP"
        echo "Checking cloud-init status..."
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$SSH_KEY_FILE" "ubuntu@${VM_IP}" \
            "cat /home/ubuntu/setup-complete.txt 2>/dev/null; tail -20 /var/log/cloud-init-output.log 2>/dev/null" 2>/dev/null || true
        break
    fi
    echo "  Waiting for SSH... ($i/60)"
    sleep 5
done

# --- Final output ---
echo ""
echo "✅ VM setup complete!"
echo "VM Name: $VM_NAME"
echo "Bundle: $VM_BUNDLE_DIR"
echo "Symlink: $WORKSPACE_UTM_DIR"
echo "Shared directory: $HOST_SHARE_PATH -> $GUEST_MOUNT_PATH"
echo ""
echo "🔐 SSH key: $SSH_KEY_FILE"
echo "🔐 Password: $RANDOM_PASSWORD (saved to $PASSWORDS_FILE)"
if [ -n "$VM_IP" ]; then
    echo "🔗 ssh -i $SSH_KEY_FILE ubuntu@${VM_IP}"
fi
echo ""
echo "📝 Commands:"
echo "  Start VM:   $UTMCTL start \"$VM_NAME\""
echo "  Exec cmd:   $UTMCTL exec \"$VM_NAME\" -- <command>"
echo "  Get IP:     $UTMCTL ip-address \"$VM_NAME\""
