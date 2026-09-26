#!/bin/bash
# Creates a VM with Apple Virtualization (AVF) backend using a raw disk image
# This approach avoids QCOW2 format entirely, allowing disk size control via `dd`
#
# Key differences from create-utm-vm-with-shared-mount.sh:
# - Uses backend:apple (Apple Virtualization.framework) instead of backend:qemu
# - Uses a raw disk image created with `dd` (not QCOW2 cloud image)
# - Requires Ubuntu 26.04 Live Server ISO for installation (not cloud image .img)
# - Boot order: ISO (installer) → install Ubuntu → cloud-init configures the OS
# - Disk size is controlled by `dd` (file size = virtual disk size for raw format)
#
# Why this works:
# - Apple Virtualization uses raw disk images where file size = virtual disk size
# - Unlike QCOW2, raw image size can be extended with `dd` (no header to modify)
# - The Ubuntu Server ISO uses Subiquity installer which supports autoinstall via
#   cloud-init config drive (cidata label)
# - No qemu-img, no Homebrew required
#
# Prerequisites:
# - UTM 4.7.5 on macOS 26+ (Apple Silicon)
# - Ubuntu 26.04 LTS Live Server ISO for arm64 (downloaded automatically)
# - No qemu-img, no Homebrew required
#
set -euo pipefail

# --- Configuration ---
CONTAINER_WORKSPACE_DIR="${CONTAINER_WORKSPACE_DIR:-/Users/ericweber/Desktop/Eric/Projects/container-workspace}"
VM_NAME="container-workspace-utm-vm"
GUEST_MOUNT_PATH="/mnt/container-workspace"
HOST_SHARE_PATH="${CONTAINER_WORKSPACE_DIR}"

VM_MEMORY_GB=16
VM_CPU_COUNT=8
VM_DISK_SIZE_GB=16

# --- Derived values ---
VM_DISK_SIZE_MIB=$((VM_DISK_SIZE_GB * 1024))
VM_MEMORY_MIB=$((VM_MEMORY_GB * 1024))

# UTM paths
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
UTM_DOCS_DIR="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

# Ubuntu 26.04 LTS Live Server ISO for ARM64 (Resolute Raccoon)
UBUNTU_ISO_URL="https://cdimage.ubuntu.com/releases/resolute/release/ubuntu-26.04-live-server-arm64.iso"
UBUNTU_ISO_FILENAME="ubuntu-26.04-live-server-arm64.iso"

# Disk image (raw format, created with dd)
RAW_DISK_FILE="${UTM_DOCS_DIR}/${VM_NAME}.raw"

# Cloud-init files
CLOUD_INIT_DIR="${CONTAINER_WORKSPACE_DIR}/utm-vm/cloud-init"

echo "============================================"
echo "  UTM VM Creation (AVF + Raw Disk)"
echo "  VM Name: $VM_NAME"
echo "  Backend: apple (Apple Virtualization)"
echo "  Disk: ${VM_DISK_SIZE_GB}GB raw image"
echo "  Memory: ${VM_MEMORY_GB}GB"
echo "  CPUs: ${VM_CPU_COUNT}"
echo "============================================"

# --- Generate SSH keys ---
SSH_KEY_DIR="${CONTAINER_WORKSPACE_DIR}/utm-vm/ssh-keys"
SSH_KEY_FILE="${SSH_KEY_DIR}/id_ed25519"
mkdir -p "$SSH_KEY_DIR"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "🔐 Generating SSH key pair..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "ubuntu-avf-vm"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_FILE}.pub")

# --- Generate password ---
RANDOM_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')
PASSWORD_HASH=$(openssl passwd -6 "$RANDOM_PASSWORD" 2>/dev/null || echo "")

PASSWORDS_FILE="${CONTAINER_WORKSPACE_DIR}/utm-vm/${VM_NAME}.password"
echo "$RANDOM_PASSWORD" > "$PASSWORDS_FILE" 2>/dev/null || true
chmod 600 "$PASSWORDS_FILE" 2>/dev/null || true

# --- Download Ubuntu Live Server ISO ---
UBUNTU_ISO_LOCAL="${CONTAINER_WORKSPACE_DIR}/utm-vm/${UBUNTU_ISO_FILENAME}"
mkdir -p "$(dirname "$UBUNTU_ISO_LOCAL")"

if [ ! -f "$UBUNTU_ISO_LOCAL" ]; then
    echo "📥 Downloading Ubuntu 26.04 LTS Live Server ISO (arm64)..."
    echo "   URL: $UBUNTU_ISO_URL"
    curl -L --create-dirs -o "$UBUNTU_ISO_LOCAL" "$UBUNTU_ISO_URL" 2>&1 | tail -3
    echo "✅ Downloaded: $UBUNTU_ISO_LOCAL"
    ls -lh "$UBUNTU_ISO_LOCAL"
else
    echo "✅ Ubuntu ISO already exists: $UBUNTU_ISO_LOCAL"
    ls -lh "$UBUNTU_ISO_LOCAL"
fi

# --- Create a modified Ubuntu ISO with autoinstall preseed ---
# The Ubuntu Live Server ISO uses GRUB via UEFI. UTM's AVF backend with
# UEFIBoot=true ignores LinuxCommandLine (per UTM source code), so we can't
# pass "autoinstall" as a kernel parameter. Instead, we modify the ISO's
# GRUB configuration to add "autoinstall ds=label" to the
# default boot entry's kernel command line.
echo "🔧 Creating autoinstall-enabled Ubuntu ISO..."

UBUNTU_ISO_MODIFIED="${CONTAINER_WORKSPACE_DIR}/utm-vm/ubuntu-26.04-live-server-autoinstall-arm64.iso"

if [ ! -f "$UBUNTU_ISO_MODIFIED" ]; then
    TEMP_ISO_DIR=$(mktemp -d)
    echo "   Extracting ISO (this may take a minute)..."

    # --- ISO Extraction ---
    # On macOS 26, `hdiutil attach` hangs on ISO mounting (known issue).
    # BSD tar (libarchive) reads ISO 9660 natively, so we use it as primary.
    # If tar fails, fall back to hdiutil attach (may hang on macOS 26).
    echo "   Extracting ISO contents using tar -xf (BSD tar reads ISO 9660 natively)..."
    tar -xf "$UBUNTU_ISO_LOCAL" -C "$TEMP_ISO_DIR" 2>/dev/null || {
        echo "   tar -xf failed, trying hdiutil attach fallback..."
        HDIUTIL_OUTPUT=$(hdiutil attach -nobrowse -readonly "$UBUNTU_ISO_LOCAL" 2>&1)
        MOUNT_POINT=$(echo "$HDIUTIL_OUTPUT" | grep '/Volumes' | awk '{print $NF}' | head -1)
        if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
            echo "   ISO mounted at: $MOUNT_POINT"
            cp -R "$MOUNT_POINT/"* "$TEMP_ISO_DIR/" 2>/dev/null || cp -R "$MOUNT_POINT"/. "$TEMP_ISO_DIR/"
            hdiutil detach "$MOUNT_POINT" 2>/dev/null || true
        else
            echo "   ❌ Could not extract ISO contents"
            echo "   hdiutil output: $HDIUTIL_OUTPUT"
            rm -rf "$TEMP_ISO_DIR"
            exit 1
        fi
    }

    # chmod -R u+w — tar preserves ISO's read-only file modes; we need write access for sed
    chmod -R u+w "$TEMP_ISO_DIR"

    if [ ! -d "$TEMP_ISO_DIR/boot/grub" ]; then
        echo "   ❌ ISO extraction failed — boot/grub directory not found"
        rm -rf "$TEMP_ISO_DIR"
        exit 1
    fi

    # Modify GRUB configuration to add autoinstall parameter
    # The grub.cfg has entries like: "linux /casper/vmlinuz ... --"
    # We add "autoinstall ds=label" before the trailing "---"
    GRUB_CFG="${TEMP_ISO_DIR}/boot/grub/grub.cfg"
    if [ -f "$GRUB_CFG" ]; then
        echo "   Adding autoinstall ds=label to GRUB config..."
        # ds=label tells cloud-init to search for cidata-labeled volume
        # autoinstall triggers Subiquity installer automation
        sed -i '' 's|linux \(.*\) ---|linux \1 autoinstall ds=label ---|g' "$GRUB_CFG"
    else
        echo "   ⚠️  No grub.cfg found, trying /boot/grub/grub-efi.cfg..."
        GRUB_CFG="${TEMP_ISO_DIR}/boot/grub/grub-efi.cfg"
        if [ -f "$GRUB_CFG" ]; then
            sed -i '' 's|linux \(.*\) ---|linux \1 autoinstall ds=label ---|g' "$GRUB_CFG"
        else
            echo "   ⚠️  GRUB config not found in expected location"
        fi
    fi

    # Create new ISO with modified GRUB config
    # -udf: UDF filesystem for native UEFI boot (no El Torito catalog needed)
    # -iso: ISO 9660 format
    # -joliet: Joliet extension for Windows compatibility
    echo "   Creating modified ISO (UDF + ISO 9660 hybrid for UEFI boot)..."
    hdiutil makehybrid -udf -iso -joliet -o "$UBUNTU_ISO_MODIFIED" "$TEMP_ISO_DIR" 2>&1

    # Clean up temp directory
    rm -rf "$TEMP_ISO_DIR"

    if [ -f "$UBUNTU_ISO_MODIFIED" ]; then
        echo "✅ Modified ISO created: $UBUNTU_ISO_MODIFIED"
        ls -lh "$UBUNTU_ISO_MODIFIED"
    else
        echo "❌ Failed to create modified ISO, using original"
        cp "$UBUNTU_ISO_LOCAL" "$UBUNTU_ISO_MODIFIED"
    fi
else
    echo "✅ Modified ISO already exists: $UBUNTU_ISO_MODIFIED"
    ls -lh "$UBUNTU_ISO_MODIFIED"
fi

# --- Create raw disk image with dd ---
echo "📀 Creating ${VM_DISK_SIZE_GB}GB raw disk image with GPT..."
# Create a sparse file of the specified size
# dd with bs=1M count=0 seek=N creates a sparse file of N MiB
dd if=/dev/zero of="$RAW_DISK_FILE" bs=1M count=0 seek="$VM_DISK_SIZE_MIB"

# Write a minimal GPT partition table so VZ's UEFI recognizes the disk
# An all-zeros raw file can cause VZ's UEFI to crash during device enumeration
# The GPT has: protective MBR at LBA 0, primary header at LBA 1, partition entries at LBA 2,
# and backup header at the last LBA
python3 - "$RAW_DISK_FILE" << 'GPTEOF'
import struct, sys, binascii
disk_file = sys.argv[1]
with open(disk_file, 'r+b') as f:
    disk_size = f.seek(0, 2)
    f.seek(0)
    # Protective MBR (LBA 0) — partition type 0xEE indicates GPT protective MBR
    mbr = bytearray(512)
    mbr[510] = 0x55
    mbr[511] = 0xAA
    f.write(mbr)
    # Primary GPT Header (LBA 1)
    header = bytearray(512)
    header[0:6] = binascii.unhexlify(b'4546492050415254')  # GPT signature "EFI PART"
    struct.pack_into('<I', header, 10, 0x00010000)
    struct.pack_into('<I', header, 12, 92)
    struct.pack_into('<Q', header, 24, 1)
    alt_lba = disk_size // 512 - 1
    struct.pack_into('<Q', header, 32, alt_lba)
    struct.pack_into('<Q', header, 40, 34)
    struct.pack_into('<Q', header, 48, alt_lba - 33)
    struct.pack_into('<Q', header, 72, 2)
    struct.pack_into('<I', header, 80, 128)
    struct.pack_into('<I', header, 84, 128)
    table = bytearray(128 * 128)
    table_crc = binascii.crc32(table) & 0xFFFFFFFF
    struct.pack_into('<I', header, 88, table_crc)
    header[16:20] = b'\x00' * 4
    header_crc = binascii.crc32(header[:92]) & 0xFFFFFFFF
    struct.pack_into('<I', header, 16, header_crc)
    f.seek(512)
    f.write(header)
    # Partition entries (LBA 2)
    f.seek(1024)
    f.write(table)
    # Backup GPT Header (last LBA)
    f.seek(alt_lba * 512)
    backup = bytearray(header)
    struct.pack_into('<Q', backup, 24, alt_lba)
    struct.pack_into('<Q', backup, 32, 1)
    f.write(backup[:512])
print("✅ GPT partition table written to disk image")
GPTEOF

if [ $? -ne 0 ]; then
    echo "⚠️  GPT initialization failed, disk will be all zeros (UEFI may fail)"
fi

echo "✅ Raw disk image created: $RAW_DISK_FILE"
ls -lh "$RAW_DISK_FILE"
echo "   Actual disk usage (sparse): $(du -sh "$RAW_DISK_FILE" | cut -f1)"

# --- Create cloud-init config drive ---
# For the Ubuntu Server ISO (Subiquity installer), user-data must use the
# autoinstall format (#autoinstall, not #cloud-config)
echo "📦 Creating cloud-init config drive (autoinstall format)..."

mkdir -p "$CLOUD_INIT_DIR"

# Autoinstall user-data for Subiquity installer
# This configures the installer AND post-install cloud-init
cat > "${CLOUD_INIT_DIR}/user-data" << 'AUTOINSTALL_END'
#autoinstall
autoinstall:
  version: 1
  locale: en_US.UTF-8
  storage:
    layout:
      name: direct
    swap:
      none: true
  identity:
    hostname: container-workspace-vm
    username: ubuntu
    password: {{PASSWORD_HASH}}
  ssh:
    install-server: true
    allow-pw: true
    authorized-keys:
      - {{SSH_PUBLIC_KEY}}
  packages:
    - qemu-guest-agent
    - docker.io
    - python3-pip
    - curl
    - wget
    - net-tools
    - cloud-guest-utils
  user-data:
    package_update: true
    package_upgrade: true
    packages:
      - qemu-guest-agent
      - docker.io
      - python3-pip
      - curl
      - wget
      - net-tools
      - cloud-guest-utils
    runcmd:
      - systemctl enable --now qemu-guest-agent
      - systemctl enable --now docker
      - growpart /dev/sda 1 || true
      - resize2fs /dev/sda1 || true
      - echo "=== SETUP COMPLETE ===" > /home/ubuntu/setup-complete.txt
      - echo "Timestamp: $(date)" >> /home/ubuntu/setup-complete.txt
      # Mount shared directory via virtiofs (AVF) — tolerate failure
      - mount -t virtiofs shared /mnt/container-workspace 2>/dev/null || true
AUTOINSTALL_END

# Replace placeholders in user-data
sed -i '' "s|{{SSH_PUBLIC_KEY}}|${SSH_PUBLIC_KEY}|g" "${CLOUD_INIT_DIR}/user-data"
sed -i '' "s|{{PASSWORD_HASH}}|${PASSWORD_HASH}|g" "${CLOUD_INIT_DIR}/user-data"

# Verify placeholders were replaced
if grep -q '{{' "${CLOUD_INIT_DIR}/user-data"; then
    echo "❌ Placeholder substitution failed"
    exit 1
fi

# Create meta-data
cat > "${CLOUD_INIT_DIR}/meta-data" << METADATA
instance-id: iid-container-workspace-avf-vm
local-hostname: container-workspace-vm
METADATA

# Create empty network-data
touch "${CLOUD_INIT_DIR}/network-data"

# Create config drive ISO with proper structure
# Cloud-init looks for files at the root of a device with volume label "cidata"
# Files must be at ISO root, NOT in a subdirectory
CONFIG_DRIVE_ISO="${CLOUD_INIT_DIR}/config-drive.iso"
rm -f "$CONFIG_DRIVE_ISO"

# Create config drive with files at the root of a directory named "cidata"
# hdiutil makehybrid uses the directory name as the ISO volume label
# Files must be at the ISO root (inside the "cidata" directory) for cloud-init
TEMP_CIDATA_DIR=$(mktemp -d)
mkdir "${TEMP_CIDATA_DIR}/cidata"
cp "${CLOUD_INIT_DIR}/user-data" "${TEMP_CIDATA_DIR}/cidata/"
cp "${CLOUD_INIT_DIR}/meta-data" "${TEMP_CIDATA_DIR}/cidata/"
touch "${TEMP_CIDATA_DIR}/cidata/network-data"

# Create ISO from the "cidata" directory so the volume label is "cidata"
# -udf: UDF filesystem for UEFI compatibility
# -iso: ISO 9660 format
# -joliet: Joliet extension
hdiutil makehybrid -udf -iso -joliet -o "$CONFIG_DRIVE_ISO" "${TEMP_CIDATA_DIR}/cidata" 2>&1
rm -rf "$TEMP_CIDATA_DIR"

if [ ! -f "$CONFIG_DRIVE_ISO" ]; then
    echo "❌ Failed to create config drive ISO"
    exit 1
fi
echo "✅ Config drive created: $CONFIG_DRIVE_ISO"
echo "   Volume label: cidata"

# --- Ensure UTM is running ---
echo "Ensuring UTM is running..."
if ! pgrep -x UTM >/dev/null 2>&1; then
    open -a UTM
    sleep 15
else
    sleep 5
fi

# --- Clean up existing VM ---
echo "🧹 Cleaning up existing VM..."
"$UTMCTL" delete "$VM_NAME" 2>/dev/null || true
pkill UTM 2>/dev/null || true
sleep 3
open -a UTM
sleep 10

# --- Copy files to UTM sandbox ---
# AVF runs sandboxed and needs files in its Documents directory
echo "📁 Copying files to UTM sandbox..."

UBUNTU_ISO_SANDBOX="${UTM_DOCS_DIR}/ubuntu-26.04-live-server-autoinstall-arm64.iso"
cp "$UBUNTU_ISO_MODIFIED" "$UBUNTU_ISO_SANDBOX"
echo "✅ Ubuntu ISO copied to sandbox: $UBUNTU_ISO_SANDBOX"

# Raw disk is already in UTM_DOCS_DIR
echo "✅ Raw disk image ready: $RAW_DISK_FILE"

# Copy config drive to UTM Documents
CONFIG_DRIVE_SANDBOX="${UTM_DOCS_DIR}/${VM_NAME}-config.iso"
cp "$CONFIG_DRIVE_ISO" "$CONFIG_DRIVE_SANDBOX"
echo "✅ Config drive copied to sandbox: $CONFIG_DRIVE_SANDBOX"

# --- Create VM via AppleScript ---
# backend:apple uses Apple Virtualization.framework
echo "Creating VM via AppleScript (backend:apple)..."

# Generate MAC address
MAC_ADDRESS=$(python3 -c "import random; print(':'.join(f'{random.randint(0x52,0x52):02x}' for _ in range(1)) + ':' + ':'.join(f'{random.randint(0,255):02x}' for _ in range(5)))")

osascript -e 'tell application "UTM"' \
          -e "set disk to POSIX file \"${RAW_DISK_FILE}\"" \
          -e "set iso to POSIX file \"${UBUNTU_ISO_SANDBOX}\"" \
          -e "set cfg to POSIX file \"${CONFIG_DRIVE_SANDBOX}\"" \
          -e "make new virtual machine with properties {backend:apple, configuration:{name:\"${VM_NAME}\", drives:{{source:disk}, {removable:true, source:iso}, {removable:true, source:cfg}}, memory:${VM_MEMORY_MIB}, cpu cores:${VM_CPU_COUNT}, uefi:true}}" \
          -e 'end tell'

echo "✅ VM created and registered"
sleep 5

# Verify VM appears in UTM
if ! "$UTMCTL" list | grep -q "$VM_NAME"; then
    echo "❌ Error: VM not found in UTM after creation"
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
    echo "❌ Error: VM bundle directory not found"
    exit 1
fi

echo "VM bundle at: $VM_BUNDLE_DIR"

# --- Configure VM after creation ---
CONFIG_PLIST="${VM_BUNDLE_DIR}/config.plist"

# Dump the original config.plist for reference
echo "📋 Original config.plist:"
plutil -convert xml1 -o - "$CONFIG_PLIST" 2>/dev/null

# Copy disk images into VM bundle Data directory
# AVF requires all disk image files inside the bundle's Data/ directory
# and ImageName must be relative filenames

# Copy raw disk image
RAW_DISK_IN_BUNDLE="${VM_BUNDLE_DIR}/Data/disk.raw"
cp "$RAW_DISK_FILE" "$RAW_DISK_IN_BUNDLE"
echo "✅ Raw disk copied to: $RAW_DISK_IN_BUNDLE"

# Copy Ubuntu installer ISO
ISO_IN_BUNDLE="${VM_BUNDLE_DIR}/Data/ubuntu-installer.iso"
cp "$UBUNTU_ISO_MODIFIED" "$ISO_IN_BUNDLE"
echo "✅ Installer ISO copied to: $ISO_IN_BUNDLE"

# Copy config drive ISO
CONFIG_DRIVE_IN_BUNDLE="${VM_BUNDLE_DIR}/Data/config-drive.iso"
cp "$CONFIG_DRIVE_SANDBOX" "$CONFIG_DRIVE_IN_BUNDLE"
echo "✅ Config drive copied to: $CONFIG_DRIVE_IN_BUNDLE"

# --- Configure AVF-specific settings ---
# For AVF backend, the config.plist structure is DIFFERENT from QEMU:
# - Top-level keys: Information, System, Virtualization, Display, Drive, Network, Serial, Backend, ConfigurationVersion
# - System: Architecture, CPUCount, MemorySize (MiB), Boot
# - Boot: OperatingSystem (Linux/macOS/None), UEFIBoot (bool), EfiVariableStoragePath
# - Drive: ImageName (relative), ReadOnly (bool), Identifier, Nvme (bool)
# - Network: Mode, MacAddress — BOTH required
# - Display: array of dicts with WidthPixels, HeightPixels, PixelsPerInch
# - Virtualization: Audio, Balloon, Entropy, Keyboard, Pointer (all Bool, decode not decodeIfPresent)
# - Serial: array of dicts with Mode
# - NO QEMU-specific keys: QEMU, Sharing, Input, Interface, ImageType
# - NO SharedDirectory in config.plist (stored in app registry as bookmarks)
#
# IMPORTANT: Adding QEMU-specific keys (like Interface, ImageType) to an AVF
# config.plist causes UTM to throw "Operation not supported" (OSStatus -2700)
# because the Codable decoder rejects unknown keys.
#
# Also: UTM caches config.plist in memory — modifications require UTM restart
# to take effect. We must pkill UTM, restart, wait for registration, then
# re-apply modifications and re-copy files.

echo "🔧 Configuring AVF system parameters (replacing PlistBuddy with Python plistlib)..."

# Use Python plistlib for correct type handling (PlistBuddy Set stores wrong types)
# plistlib ensures booleans are <true/>, integers are <integer>
# Read existing config.plist and modify only what's needed
python3 - "$CONFIG_PLIST" "$MAC_ADDRESS" << 'PYEOF'
import plistlib, sys

plist_path = sys.argv[1]
mac_address = sys.argv[2]

with open(plist_path, 'rb') as f:
    plist = plistlib.load(f)

# Ensure Backend is Apple
plist['Backend'] = 'Apple'

# Ensure System dict exists with correct values
if 'System' not in plist or not isinstance(plist['System'], dict):
    plist['System'] = {}
plist['System']['Architecture'] = 'aarch64'
plist['System']['CPUCount'] = 4
plist['System']['MemorySize'] = 8192  # MiB

# Ensure Boot dict exists
if 'Boot' not in plist['System'] or not isinstance(plist['System']['Boot'], dict):
    plist['System']['Boot'] = {}
plist['System']['Boot']['OperatingSystem'] = 'Linux'
plist['System']['Boot']['UEFIBoot'] = True
# EfiVariableStoragePath — AVF UEFI firmware requires this for EFI variable storage
# UTM creates the efi_vars.fd file via VZEFIVariableStore(creatingVariableStoreAt:) in saveData()
plist['System']['Boot']['EfiVariableStoragePath'] = 'efi_vars.fd'

# Ensure Virtualization dict exists with required Bool fields
# UTM's AVF decoder requires Audio, Balloon, Entropy (decode, not decodeIfPresent)
if 'Virtualization' not in plist or not isinstance(plist['Virtualization'], dict):
    plist['Virtualization'] = {}
plist['Virtualization']['Audio'] = False
plist['Virtualization']['Balloon'] = True
plist['Virtualization']['Entropy'] = True
plist['Virtualization']['Keyboard'] = False
plist['Virtualization']['Pointer'] = False

# Ensure Display has at least one entry — UEFI boot requires a graphics device (GOP)
# For Linux guests, VZ's appleVZConfiguration() requires at least one display
if 'Display' not in plist or not isinstance(plist['Display'], list) or len(plist['Display']) == 0:
    plist['Display'] = [{
        'WidthPixels': 1920,
        'HeightPixels': 1200,
        'PixelsPerInch': 80,
    }]

# IMPORTANT: Only change ImageName fields — this is the critical fix for AVF
# AVF runs sandboxed and can only access files inside the VM bundle's Data/ directory
# ImageName must be a relative filename, not a full sandbox path
drive_files = ['disk.raw', 'ubuntu-installer.iso', 'config-drive.iso']
drive_readonly = [False, True, True]
if 'Drive' in plist and isinstance(plist['Drive'], list):
    for i, name in enumerate(drive_files):
        if i < len(plist['Drive']) and isinstance(plist['Drive'][i], dict):
            plist['Drive'][i]['ImageName'] = name
            plist['Drive'][i]['ReadOnly'] = drive_readonly[i]

# Ensure Network has MacAddress (required by AVF decoder — both Mode AND MacAddress)
if 'Network' not in plist or not isinstance(plist['Network'], list):
    plist['Network'] = [{}]
for net in plist['Network']:
    if isinstance(net, dict):
        net['Mode'] = 'Shared'
        net['MacAddress'] = mac_address

# Ensure Serial array exists (required by AVF decoder, uses decode not decodeIfPresent)
if 'Serial' not in plist or not isinstance(plist['Serial'], list):
    plist['Serial'] = []

# Ensure Information dict exists (required by AVF decoder, uses decode not decodeIfPresent)
if 'Information' not in plist or not isinstance(plist['Information'], dict):
    plist['Information'] = {}
if 'Name' not in plist['Information']:
    plist['Information']['Name'] = 'container-workspace-utm-vm'
plist['Information']['IconCustom'] = False

# NOTE: SharedDirectory is NOT stored in config.plist in UTM 4.7.5
# It uses bookmarks stored in UserDefaults (com.utmapp.UTM.plist)
# Do NOT add SharedDirectory to config.plist

# NOTE: Do NOT manually create efi_vars.fd — UTM's saveData() creates it
# via VZEFIVariableStore(creatingVariableStoreAt:) when UEFIBoot=true
# The EfiVariableStoragePath in config.plist tells UTM where to create it

# Write config.plist
with open(plist_path, 'wb') as f:
    plistlib.dump(plist, f, fmt=plistlib.FMT_XML)
print("config.plist written via plistlib (correct types, ImageName fixed)")
PYEOF

echo "=== config.plist dump ==="
plutil -convert xml1 -o - "$CONFIG_PLIST" 2>/dev/null

# Backup config.plist for debugging
cp "$CONFIG_PLIST" "${VM_BUNDLE_DIR}/config.plist.bak" 2>/dev/null || true
chmod 644 "$CONFIG_PLIST" 2>/dev/null || true

# --- Create symlink ---
WORKSPACE_UTM_DIR="${CONTAINER_WORKSPACE_DIR}/utm-vm/${VM_NAME}.utm"
if [ -e "$WORKSPACE_UTM_DIR" ] || [ -L "$WORKSPACE_UTM_DIR" ]; then
    rm -f "$WORKSPACE_UTM_DIR"
fi
mkdir -p "$(dirname "$WORKSPACE_UTM_DIR")"
ln -s "$VM_BUNDLE_DIR" "$WORKSPACE_UTM_DIR"
echo "🔗 Created symlink: $WORKSPACE_UTM_DIR -> $VM_BUNDLE_DIR"

# --- Restart UTM to apply configuration changes ---
# On macOS 26, osascript quit does NOT fully shut down UTM's backend processes.
# pkill UTM + UTMBackend + UTMServerExtension forces full restart for VM re-registration.
echo "🔄 Restarting UTM to apply configuration changes..."
pkill UTM 2>/dev/null || true
pkill -f UTMBackend 2>/dev/null || true
pkill -f UTMServerExtension 2>/dev/null || true
sleep 3
open -a UTM

# Two-phase retry loop: 20 retries × 5s = 100s total for VM registration
echo "⏳ Waiting for UTM to register the VM (up to 100s)..."
for i in $(seq 1 20); do
    if "$UTMCTL" list 2>/dev/null | grep -q "$VM_NAME"; then
        echo "   ✅ VM registered (attempt $i)"
        break
    fi
    echo "   Retry $i/20 — VM not yet registered, waiting 5s..."
    sleep 5
done

if ! "$UTMCTL" list 2>/dev/null | grep -q "$VM_NAME"; then
    echo "❌ VM not found after 20 retries"
    echo "   UTM status:"
    "$UTMCTL" list 2>&1
    exit 1
fi

# Re-copy files to Data/ after UTM restart — UTM may have cleaned up Data/ directory
echo "📁 Re-copying files to VM bundle Data/ after UTM restart..."
# Re-copy all files after restart (Data/ may have been cleaned up)
chmod -R u+w "${VM_BUNDLE_DIR}" 2>/dev/null || true
# Ensure Data directory exists
mkdir -p "${VM_BUNDLE_DIR}/Data"
cp "$RAW_DISK_FILE" "${VM_BUNDLE_DIR}/Data/disk.raw" 2>/dev/null && echo "   ✅ disk.raw copied" || echo "   ⚠️  disk.raw copy failed"
cp "$UBUNTU_ISO_MODIFIED" "${VM_BUNDLE_DIR}/Data/ubuntu-installer.iso" 2>/dev/null && echo "   ✅ ubuntu-installer.iso copied" || echo "   ⚠️  ubuntu-installer.iso copy failed"
cp "$CONFIG_DRIVE_ISO" "${VM_BUNDLE_DIR}/Data/config-drive.iso" 2>/dev/null && echo "   ✅ config-drive.iso copied" || echo "   ⚠️  config-drive.iso copy failed"
chmod -R u+w "${VM_BUNDLE_DIR}/Data" 2>/dev/null || true
# Note: efi_vars.fd is created by UTM's saveData() during VM loading.
# Do NOT delete it — UTM will create/overwrite it properly during saveData().

echo "📋 Verifying Data/ contents:"
ls -la "${VM_BUNDLE_DIR}/Data/" 2>/dev/null || echo "   ❌ Data/ directory not found!"

# Verify config.plist still has our modifications (UTM might have overwritten it)
echo "📋 Verifying config.plist ImageName fields:"
plutil -p "${VM_BUNDLE_DIR}/config.plist" 2>/dev/null | grep -i "ImageName" || echo "   ⚠️  Could not read ImageName from config.plist"

echo "🚀 Starting VM: $VM_NAME (AVF backend with raw disk)"
"$UTMCTL" start "$VM_NAME" 2>&1 || true

echo ""
echo "⏱️  Waiting for VM to initialize..."
sleep 10

echo ""
echo "============================================"
echo "📋 VM Configuration:"
echo "  Name: $VM_NAME"
echo "  Backend: apple (Apple Virtualization)"
echo "  Bundle: $VM_BUNDLE_DIR"
echo "  Symlink: $WORKSPACE_UTM_DIR"
echo "  Disk: ${VM_DISK_SIZE_GB}GB raw (${RAW_DISK_FILE})"
echo "  Installer: Ubuntu 26.04 Live Server (modified with autoinstall)"
echo "  Config drive: cidata ISO (autoinstall)"
echo "  Memory: ${VM_MEMORY_GB}GB"
echo "  CPUs: ${VM_CPU_COUNT}"
echo ""
echo "🔐 SSH access:"
echo "  Key: $SSH_KEY_FILE"
echo "  Password: $RANDOM_PASSWORD (saved to $PASSWORDS_FILE)"
echo ""
echo "🔍 If VM fails to start, check:"
echo "  1. UTM logs: log show --predicate 'process == \"UTM\"' --last 5m --info --debug"
echo "  2. VZ logs: log show --predicate 'subsystem == \"com.apple.virtualization\"' --last 5m --info --debug"
echo "  3. UTM debug: ~/.hermes/cron/output/UTM-debug.log"
echo "  4. Crash logs: ls ~/Library/Logs/DiagnosticReports/UTM*"
echo ""
echo "⚠️  NOTE: On macOS 26, VZ subsystem logging may be broken."
echo "   If VM starts and immediately stops with no VZ logs, this may be a"
echo "   macOS 26 / UTM 4.7.5 compatibility issue (see GitHub issues #7408, #7583)."
echo "============================================"
