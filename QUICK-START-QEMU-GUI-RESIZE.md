# Quick Start: QEMU VM with GUI Disk Resize

This guide explains how to create a UTM VM using the QEMU backend with a cloud image, then resize the disk via UTM's GUI before the VM starts.

## Overview

| Component | Value |
|-----------|-------|
| **Backend** | QEMU (Software Emulation) |
| **OS** | Ubuntu 26.04 LTS ARM64 (Cloud Image) |
| **Disk** | QCOW2 (resized via UTM GUI) |
| **Auth** | SSH key + password |
| **Shared Dir** | Host workspace copied into VM bundle, mounted via QEMU `-fsdev`/`-device` |

## Prerequisites

- macOS 26 (Apple Silicon arm64)
- UTM 4.7.5 installed at `/Applications/UTM.app`
- No Homebrew or `qemu-img` required
- Internet access for downloading the Ubuntu cloud image (~900MB)

## Usage

### 1. Run the script

From your terminal on macOS:

```bash
cd ~/Desktop/Eric/Projects/container-workspace/utm-vm
./create-utm-vm-with-shared-mount.sh
```

### 2. Script flow

The script performs these steps automatically:

1. **Generate SSH key pair** (if not present)
2. **Generate random password** for the `ubuntu` user
3. **Create cloud-init config drive** with `cidata` volume label
4. **Copy cloud image to UTM sandbox** (UTM's QEMU runs sandboxed)
5. **Create VM via AppleScript** (QEMU backend, AArch64, drives: cloud image + config drive)
6. **Fix config.plist** with PlistBuddy:
   - CD-ROM: `Interface=SCSI` (creates `/dev/sr0` for cloud-init detection)
   - QEMU `AdditionalArguments`: `-fsdev` + `-device` for VirtFS share
   - `Sharing` dict: `DirectoryShareMode=VirtFS` for UTM GUI display
7. **Copy host directory** into VM bundle's `Data/shared-root/` (inside sandbox)
8. **Restart UTM** (`pkill UTM` + `open -a UTM`)
9. **Prompt for disk resize** via UTM GUI ← **YOU MUST DO THIS STEP**
10. **Start the VM**
11. **Wait for SSH** and run mount helper script

### 3. Disk Resize Instructions (step 9)

```
=============================================
📋 DISK SIZE CONFIGURATION REQUIRED
=============================================

The Ubuntu cloud image has a default virtual disk size of ~2.4GB.
To increase the disk to 16GB:

  1. Open UTM.app
  2. Right-click on the VM: "container-workspace-utm-vm"
  3. Select "Edit"
  4. Under "Drives", select "VirtIO Drive" (the main disk)
  5. Choose "Resize" and set the target size to 16 GB
  6. Click "Resize", confirm the dialog, and click "Save"

=============================================

Press ENTER after you have resized the disk and clicked 'Save' in UTM...
```

**Note:** UTM uses `qemu-img resize` internally (via its bundled library) to resize QCOW2 images. You do NOT need `qemu-img` installed on the host.

### 4. Access the VM

After setup completes, the script outputs:

```
✅ VM setup complete!
VM Name: container-workspace-utm-vm
VM Bundle: ~/Desktop/Eric/Projects/container-workspace/utm-vm/container-workspace-utm-vm/utm
🔐 SSH: ssh -i ~/Desktop/Eric/Projects/container-workspace/utm-vm/container-workspace-utm-vm/ssh-keys/id_ed25519 ubuntu@<VM_IP>
```

**SSH access:**
```bash
ssh -i ~/Desktop/Eric/Projects/container-workspace/utm-vm/container-workspace-utm-vm/ssh-keys/id_ed25519 ubuntu@192.168.65.60
```

**Password:** Saved in `~/Desktop/Eric/Projects/container-workspace/utm-vm/container-workspace-utm-vm/container-workspace-utm-vm.password`

## Disk Resize Instructions (Repeatable)

If you need to resize the disk later:

1. Stop the VM: `utmctl stop "container-workspace-utm-vm"`
2. Open UTM.app
3. Right-click the VM → "Edit" → "Drives" → select "VirtIO Drive" → "Resize"
4. Enter new size → Click "Resize" → Confirm → Click "Save"
5. Start VM: `utmctl start "container-workspace-utm-vm"`

**Note:** After resizing, cloud-init's `growpart` + `resize2fs` in the `runcmd` section will expand the partition and filesystem to fill the new disk size on next boot.

## Why No qemu-img?

macOS doesn't have `qemu-img` as a standalone executable:
- QEMU is bundled inside UTM as a shared library (`.dylib`), not an executable binary
- No Homebrew available in this environment
- UTM's GUI uses the bundled library to resize disks internally

The GUI resize is the only way to resize QCOW2 images without `qemu-img` on the host. UTM handles this by calling `qemu-img resize` via its linked `.dylib` library.

## Shared Directory Setup

The script uses QEMU's `-fsdev`/`-device` arguments (passed via UTM's `AdditionalArguments`) to create a VirtFS share:

| Config | Value |
|--------|-------|
| **QEMU arguments** | `-fsdev local,id=virtfs0,path=<sandbox_path>,security_model=mapped-xattr` + `-device virtio-9p-pci,fsdev=virtfs0,mount_tag=share` |
| **Host path** | `${UTM_DOCS_DIR}/${VM_NAME}.utm/Data/shared-root/` (inside UTM's sandbox) |
| **Guest mount** | `/mnt/container-workspace` (9p filesystem with tag `share`) |
| **Mount tag** | `share` (fixed by UTM convention) |

**Why this approach:**
- UTM's App Sandbox requires bookmarks (GUI-only) for host paths outside the VM bundle
- By copying the host directory INTO the VM bundle's `Data/` directory, QEMU can access it directly
- QEMU `-fsdev`/`-device` format is the same one UTM generates internally (verified from `sharingArguments` in `UTMQemuConfiguration+Arguments.swift`)
- The `AdditionalArguments` approach bypasses UTM's `Sharing` config which requires GUI-created bookmarks

**QEMU config.plist structure:**
```
QEMU:
  AdditionalArguments: [
    {Final: "-fsdev"},
    {Final: "local,id=virtfs0,path=<sandbox_path>,security_model=mapped-xattr"},
    {Final: "-device"},
    {Final: "virtio-9p-pci,fsdev=virtfs0,mount_tag=share"}
  ]
Sharing:
  DirectoryShareMode: "VirtFS"
  DirectoryShareReadOnly: false
  ClipboardSharing: false
```

**Note:** If `DirectoryShareMode=VirtFS` and no bookmark is set, UTM will show a warning in its GUI about the shared directory, but the QEMU argument in `AdditionalArguments` still works because QEMU handles it directly.

## File Locations

```
~/Desktop/Eric/Projects/container-workspace/utm-vm/
├── ubuntu-26.04-server-cloudimg-arm64.img  # Cloud image (downloaded)
├── container-workspace-utm-vm/              # VM-specific directory
│   ├── utm/                                  # VM bundle (*.utm) - self-contained
│   │   ├── config.plist                      # VM configuration
│   │   └── Data/
│   │       ├── disk.img                      # Cloud image (copied by UTM)
│   │       ├── config-drive.iso              # Config drive (cloud-init)
│   │       └── shared-root/                  # Host workspace (for VirtFS)
│   ├── container-workspace-utm-vm.password   # Random password
│   ├── ssh-keys/
│   │   ├── id_ed25519
│   │   └── id_ed25519.pub
│   ├── cloud-init/
│   │   ├── user-data
│   │   ├── meta-data
│   │   ├── network-data
│   │   └── config-drive.iso
│   └── .utm-shared/
│       └── mount-shared.sh                   # Mount helper (run inside VM)
└── create-utm-vm-with-shared-mount.sh         # Main script
```

## Related Documentation

- `UTM_VM_CREATION.md` — Detailed technical documentation
