# UTM VM Config Drive Comparison Doc

Purpose: Document the exact config.plist state and ISO placement for both the
PlistBuddy-based (working) and pure-osascript (current) script versions,
so we can make the osascript version produce an identical config.

## Setup

Run both scripts on the macOS host, deleting the VM between runs:

```bash
# Delete VM before each run:
/Applications/UTM.app/Contents/MacOS/utmctl delete container-workspace-utm-vm 2>/dev/null || true

# After script completes, run inspection commands (see sections below)
```

---

## SECTION A: PlistBuddy-based (working) version

The OLD script that uses PlistBuddy to patch `Drive:1` after VM creation.
This version successfully creates a VM where cloud-init runs.

### A.1 VM bundle location
```
VM_BUNDLE_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm
```

### A.2 config.plist — Drive entries
Run this on macOS:
```bash
/usr/libexec/PlistBuddy -c "Print :Drive" "$VM_BUNDLE_DIR/config.plist"
```

Fill in the output:

```
=== PlistBuddy output for :Drive ===

Array {
    Dict {
        Interface = VirtIO
        Identifier = 88E01B15-9625-4232-81BE-188939B381D2
        InterfaceVersion = 1
        ReadOnly = false
        ImageName = ubuntu-26.04-server-cloudimg-arm64.qcow2
        ImageType = Disk
    }
    Dict {
        Interface = SCSI
        Identifier = 2E571B8E-6C04-4FA4-93D6-8C511562253F
        InterfaceVersion = 1
        ReadOnly = true
        ImageName = config-drive.iso
        ImageType = CD
    }
}

```

### A.3 config.plist — Drive raw XML
```bash
plutil -convert xml1 -o - "$VM_BUNDLE_DIR/config.plist" | grep -A50 '<key>Drive</key>'
```

```
=== XML output for Drive ===


	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>88E01B15-9625-4232-81BE-188939B381D2</string>
			<key>ImageName</key>
			<string>ubuntu-26.04-server-cloudimg-arm64.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
		<dict>
			<key>Identifier</key>
			<string>2E571B8E-6C04-4FA4-93D6-8C511562253F</string>
			<key>ImageName</key>
			<string>config-drive.iso</string>
			<key>ImageType</key>
			<string>CD</string>
			<key>Interface</key>
			<string>SCSI</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<true/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>container-workspace-utm-vm</string>
		<key>UUID</key>
		<string>5B7B58DE-95A5-4E99-989F-AE8616481D6D</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>

```

### A.4 Data directory contents
```bash
ls -la "$VM_BUNDLE_DIR/Data/"
```

```
=== Data/ directory ===

total 6333320
drwxr-xr-x@ 5 ericweber  staff         160 Sep 26 14:54 .
drwxr-xr-x@ 4 ericweber  staff         128 Sep 26 14:55 ..
-rw-r--r--@ 1 ericweber  staff      921600 Sep 26 14:54 config-drive.iso
-rw-r--r--@ 1 ericweber  staff      655360 Sep 26 14:55 efi_vars.fd
-rw-r--r--@ 1 ericweber  staff  3286499328 Sep 26 14:56 ubuntu-26.04-server-cloudimg-arm64.qcow2


```

### A.5 ISO file info
```bash
ls -la "$VM_BUNDLE_DIR/Data/"*.iso
hdiutil imageinfo "$VM_BUNDLE_DIR/Data/"*.iso 2>/dev/null | grep -E "Total Bytes|partition-name|partition-filesystems"
```

```
=== ISO in Data/ ===
-rw-r--r--@ 1 ericweber  staff  921600 Sep 26 14:54 /Users/ericweber/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm/Data/config-drive.iso

	Total Bytes: 921600
			partition-name: CIDATA
			partition-filesystems:
			partition-name: 

```

---

## SECTION B: Pure osascript version (current)

The NEW script that uses only osascript for VM configuration.

### B.1 VM bundle location
```
VM_BUNDLE_DIR=~/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm
```

### B.2 config.plist — Drive entries
```bash
/usr/libexec/PlistBuddy -c "Print :Drive" "$VM_BUNDLE_DIR/config.plist"
```

```
=== PlistBuddy output for :Drive ===

Array {
    Dict {
        Interface = VirtIO
        Identifier = E3E57C7F-6B78-4B0B-9B21-952744B4647F
        InterfaceVersion = 1
        ReadOnly = false
        ImageName = ubuntu-26.04-server-cloudimg-arm64-2.qcow2
        ImageType = Disk
    }
    Dict {
        InterfaceVersion = 1
        Identifier = C883C945-D294-41B1-983E-BB6F9252999E
        ReadOnly = true
        ImageType = CD
        Interface = SCSI
    }
}


```

### B.3 config.plist — Drive raw XML
```bash
plutil -convert xml1 -o - "$VM_BUNDLE_DIR/config.plist" | grep -A50 '<key>Drive</key>'
```

```
=== XML output for Drive ===

	<key>Drive</key>
	<array>
		<dict>
			<key>Identifier</key>
			<string>E3E57C7F-6B78-4B0B-9B21-952744B4647F</string>
			<key>ImageName</key>
			<string>ubuntu-26.04-server-cloudimg-arm64-2.qcow2</string>
			<key>ImageType</key>
			<string>Disk</string>
			<key>Interface</key>
			<string>VirtIO</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<false/>
		</dict>
		<dict>
			<key>Identifier</key>
			<string>C883C945-D294-41B1-983E-BB6F9252999E</string>
			<key>ImageType</key>
			<string>CD</string>
			<key>Interface</key>
			<string>SCSI</string>
			<key>InterfaceVersion</key>
			<integer>1</integer>
			<key>ReadOnly</key>
			<true/>
		</dict>
	</array>
	<key>Information</key>
	<dict>
		<key>IconCustom</key>
		<false/>
		<key>Name</key>
		<string>container-workspace-utm-vm</string>
		<key>UUID</key>
		<string>924BEFAD-9A78-465B-A132-77C0CC540CC2</string>
	</dict>
	<key>Input</key>
	<dict>
		<key>MaximumUsbShare</key>
		<integer>3</integer>
		<key>UsbBusSupport</key>
		<string>3.0</string>
		<key>UsbSharing</key>
		<false/>
	</dict>
	<key>Network</key>
	<array>
		<dict>
			<key>Hardware</key>


```

### B.4 Data directory contents
```bash
ls -la "$VM_BUNDLE_DIR/Data/"
```

```
=== Data/ directory ===

drwxr-xr-x@ 4 ericweber  staff         128 Sep 26 14:57 .
drwxr-xr-x@ 4 ericweber  staff         128 Sep 26 14:58 ..
-rw-r--r--@ 1 ericweber  staff      655360 Sep 26 14:58 efi_vars.fd
-rw-r--r--@ 1 ericweber  staff  2589392896 Sep 26 14:58 ubuntu-26.04-server-cloudimg-arm64-2.qcow2


```

### B.5 ISO file info
```bash
ls -la "$VM_BUNDLE_DIR/Data/"*.iso 2>/dev/null
hdiutil imageinfo "$VM_BUNDLE_DIR/Data/"*.iso 2>/dev/null | grep -E "Total Bytes|partition-name|partition-filesystems"
```

```
=== ISO in Data/ ===

zsh: no matches found: /Users/ericweber/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm/Data/*.iso
zsh: no matches found: /Users/ericweber/Library/Containers/com.utmapp.UTM/Data/Documents/container-workspace-utm-vm.utm/Data/*.iso

```

---

## SECTION C: Diff analysis

Compare A and B. List the exact differences in the Drive entries:

```
=== Differences between PlistBuddy and osascript approaches ===

<!-- FILL IN AFTER BOTH RUNS -->

Key differences:
1. [Drive count]
   - PlistBuddy version:
   - osascript version:

2. [CD-ROM drive entry]
   - PlistBuddy version:
   - osascript version:

3. [ImageName for CD-ROM]
   - PlistBuddy version:
   - osascript version:

4. [Interface for CD-ROM]
   - PlistBuddy version:
   - osascript version:

5. [ImageType for CD-ROM]
   - PlistBuddy version:
   - osascript version:

6. [ReadOnly for CD-ROM]
   - PlistBuddy version:
   - osascript version:

7. [ISO filename in Data/]
   - PlistBuddy version:
   - osascript version:

8. [Identifier for CD-ROM drive]
   - PlistBuddy version:
   - osascript version:
```

---

## SECTION D: Fix plan

Based on the differences, modify the osascript approach to match:

```
=== Fix plan for osascript version ===

<!-- Fill in after comparing A and B -->

1. [What to change in osascript block:]
   <!-- -->

2. [What to change in ISO copy:]
   <!-- -->

3. [Any additional PlistBuddy fallback if needed:]
   <!-- -->
```
