# UTM VM Creation — Technical Documentation

## Quick Start

```bash
cd ~/Desktop/Eric/Projects/container-workspace/utm-vm
./create-utm-vm-with-shared-mount.sh
```

## Architecture

- **VM Backend**: QEMU (software emulation, not Apple Virtualization)
- **OS**: Ubuntu 26.04 LTS ARM64 (cloud image)
- **Disk**: QCOW2 (cloud image, resized via UTM GUI)
- **Auth**: SSH key + password
- **Shared Dir**: QEMU `-fsdev`/`-device` via `AdditionalArguments`

## Script Flow

1. Generate SSH key pair
2. Generate random password for `ubuntu` user
3. Create cloud-init config drive (with `cidata` volume label)
4. Copy cloud image + config drive to UTM sandbox
5. Ensure UTM is running
6. Delete any existing VM
7. Create VM via AppleScript (QEMU backend, AArch64)
8. Copy VM bundle to desktop working directory
9. **Modify config.plist**:
   - CD-ROM: `Interface=SCSI` (creates `/dev/sr0` for cloud-init)
   - QEMU `AdditionalArguments`: `-fsdev`/`-device` for VirtFS share
10. **Copy config.plist + shared-root to UTM sandbox**
11. **Do NOT restart UTM** — UTM reads config.plist on `utmctl start`
12. Prompt for disk resize via UTM GUI
13. Start VM → wait for SSH → mount shared directory

## Key Technical Details

### CD-ROM Interface: SCSI

On QEMU's ARM virt machine (`-M virt`), there is no IDE controller. The CD-ROM must use SCSI interface to create `/dev/sr0` in the guest, which cloud-init's NoCloud datasource scans for the `cidata` volume label.

- `Interface=SCSI` → QEMU creates `scsi-cd` device → guest sees `/dev/sr0`
- `Interface=USB` (AppleScript default) → QEMU creates `usb-storage` device → guest sees `/dev/sdX` (cloud-init doesn't scan USB devices)
- `Interface=IDE` → QEMU's `-M virt` has no IDE controller → CD-ROM is silently dropped

### Shared Directory (VirtFS/9p)

#### UTM's Sharing Configuration

UTM's QEMU backend has a `Sharing` dict with:
- `DirectoryShareMode`: `VirtFS` or `WebDAV`
- `DirectoryShareReadOnly`: bool
- `ClipboardSharing`: bool

The actual host path (`directoryShareUrl`) is **not saved in config.plist** — it's a transient security-scoped bookmark set via the GUI only. Without a bookmark, UTM's QEMU backend can't generate the `-fsdev` argument for VirtFS.

#### Script's Approach

The script bypasses UTM's share management by using **QEMU `AdditionalArguments`** to pass `-fsdev`/`-device` directly to QEMU:

```
QEMU.AdditionalArguments = [
    {Final: "-fsdev"},
    {Final: "local,id=virtfs0,path=<absolute_sandbox_path>,security_model=mapped-xattr"},
    {Final: "-device"},
    {Final: "virtio-9p-pci,fsdev=virtfs0,mount_tag=share"}
]
```

This matches the exact format UTM generates internally (from `UTMQemuConfiguration+Arguments.swift` `sharingArguments` function).

#### Host Path Resolution

The host path points to a directory **inside UTM's sandbox**:
```
~/Library/Containers/com.utmapp.UTM/Data/Documents/<VM_NAME>.utm/Data/shared-root/
```

This path is accessible by QEMU (running as a child of UTM) without a security-scoped bookmark.

### PlistBuddy Commands

All config.plist modifications use the `Add`/`Set` pattern for idempotency:
```
PlistBuddy -c "Add :Key:SubKey string value" file.plist 2>/dev/null || \
    PlistBuddy -c "Set :Key:SubKey string value" file.plist 2>/dev/null || true
```

This ensures the command works whether the key already exists (from UTM defaults) or doesn't exist yet.

### No QEMU Restart

**Critical:** Do NOT restart UTM after modifying config.plist. UTM reads config.plist from disk when the VM is started (`utmctl start`), not when the UTM app starts.

The previous approach of `pkill UTM` + `open -a UTM` after config changes caused the VM to show as "unavailable" because:
1. UTM's background processes (UTMBackend, UTMServerExtension) are killed mid-register
2. UTM's VM registry becomes corrupted
3. When UTM restarts, it can't find the VM

## QEMU Argument Format

UTM's QEMU backend generates VirtFS arguments in this format (from UTM source):

```swift
// From sharingArguments in UTMQemuConfiguration+Arguments.swift
f("-fsdev")
"local"
"id=virtfs0"
"path="  // URL resolved from bookmark
"url"  // security_model=mapped-xattr
if sharing.isDirectoryShareReadOnly {
    "readonly=on"
}
f()  // end -fsdev

f("-device")
"virtio-9p-pci"
"fsdev=virtfs0"
"mount_tag=share"
```

## Debugging

### Check config.plist

```bash
plutil -lint ~/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm/config.plist
plutil -p ~/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm/config.plist
```

### Check QEMU command line

```bash
ps aux | grep qemu-system-aarch64
```

### Check 9p device in guest

After SSH into the VM:
```bash
ls /sys/bus/virtio/drivers/ | grep 9p
# Should show: 9p
```

### Enable UTM debug logging

```bash
defaults write com.utmapp.UTM QEmuLoggingEnabled -bool true
# Then restart UTM and start the VM
log stream --predicate 'subsystem == "com.utmapp.UTM"' --last 10m
```
