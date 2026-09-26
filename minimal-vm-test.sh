#!/bin/bash
# minimal-vm-test.sh - Minimal VM test with Ubuntu 26.04 cloud image
# Fixes the UEFI shell issue by properly attaching the cloud image as a disk

set -euo pipefail

VM_NAME="minimal-test"
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
UTM_DOCS_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# Ubuntu 26.04 cloud image for ARM64
IMAGE_PATH="$HOME/Desktop/Eric/Projects/container-workspace/utm-vm/ubuntu-26.04-server-cloudimg-arm64.img"
if [ ! -f "$IMAGE_PATH" ]; then
    echo "❌ Error: Ubuntu 26.04 cloud image not found at $IMAGE_PATH"
    echo "   Download: curl -o \"$IMAGE_PATH\" \"https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-arm64.img\""
    exit 1
fi

# Create cloud-init config
CLOUD_INIT_DIR="$HOME/Desktop/Eric/Projects/container-workspace/utm-vm/minimal-cloud-init"
mkdir -p "$CLOUD_INIT_DIR/config-drive/openstack/latest"

cat > "$CLOUD_INIT_DIR/config-drive/openstack/latest/user-data" << 'EOF'
#cloud-config
hostname: minimal-test
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
ssh_pwauth: false
package_update: true
packages:
  - curl
runcmd:
  - echo "=== Cloud-init completed successfully ===" > /home/ubuntu/startup-complete.log
  - echo "System ready at $(date)" >> /home/ubuntu/startup-complete.log
EOF

cat > "$CLOUD_INIT_DIR/config-drive/openstack/latest/meta-data" << 'EOF'
instance-id: iid-minimal-test
local-hostname: minimal-test
EOF

touch "$CLOUD_INIT_DIR/config-drive/openstack/latest/network-data"

# Create config drive ISO
CONFIG_DRIVE_ISO="$CLOUD_INIT_DIR/config-drive.iso"
rm -f "$CONFIG_DRIVE_ISO"
hdiutil makehybrid -iso -joliet -o "$CONFIG_DRIVE_ISO" "$CLOUD_INIT_DIR/config-drive"

echo "✅ Config drive created: $CONFIG_DRIVE_ISO"

# Ensure UTM is running
echo "🔄 Starting UTM..."
if ! pgrep -x UTM >/dev/null 2>&1; then
    open -a UTM
    sleep 15
else
    sleep 5
fi

# Delete any existing VM
"$UTMCTL" delete "$VM_NAME" 2>/dev/null || true
pkill UTM 2>/dev/null || true
sleep 3
open -a UTM
sleep 10

# Create minimal VM via AppleScript
# Key fix: attach cloud image as a DISK (not just removable), config drive as removable
echo "🚀 Creating minimal VM with Ubuntu 26.04..."
osascript -e 'tell application "UTM"' \
          -e "set img to POSIX file \"${IMAGE_PATH}\"" \
          -e "set cfg to POSIX file \"${CONFIG_DRIVE_ISO}\"" \
          -e "make new virtual machine with properties {backend:qemu, configuration:{name:\"${VM_NAME}\", architecture:\"aarch64\", drives:{{source:img}, {removable:true, source:cfg}}, memory:4096, cpu cores:2, hypervisor:true, uefi:true}}" \
          -e 'end tell'

echo "✅ VM created via AppleScript"
sleep 5

# Verify VM exists and get bundle path
VM_BUNDLE_DIR=""
for dir in "${UTM_DOCS_DIR}/${VM_NAME}"*.utm; do
    if [ -d "$dir" ]; then
        VM_BUNDLE_DIR="$dir"
        break
    fi
done

if [ -z "$VM_BUNDLE_DIR" ]; then
    echo "❌ VM bundle not found"
    exit 1
fi

CONFIG_PLIST="${VM_BUNDLE_DIR}/config.plist"
echo "📂 VM bundle: $VM_BUNDLE_DIR"

# Configure QEMU for serial console visibility
echo "🔧 Configuring serial console..."
/usr/libexec/PlistBuddy -c "Add :QEMU:SerialPortEnabled bool true" "$CONFIG_PLIST" 2>/dev/null || true
/usr/libexec/PlistReader -c "Print :QEMU:SerialPorts" "$CONFIG_PLIST" 2>/dev/null || echo "Adding serial port config..."

# Restart UTM with new config
echo "🔄 Restarting UTM..."
pkill UTM 2>/dev/null || true
sleep 2
open -a UTM
sleep 10

# Start VM
echo "▶️ Starting minimal VM..."
"$UTMCTL" start "$VM_NAME"

echo ""
echo "📋 Instructions:"
echo "  1. UTM.app should now be running with the minimal-test VM"
echo "  2. If VM isn't running, click the ▶️ button in UTM GUI"
echo "  3. A terminal window will appear showing serial console output"
echo "  4. Watch for kernel boot, cloud-init, and Ubuntu startup messages"
echo ""
echo "To check status:"
echo "  $UTMCTL status \"$VM_NAME\""
echo ""
echo "✅ Setup complete. Monitor the UTM GUI terminal for boot progress."
