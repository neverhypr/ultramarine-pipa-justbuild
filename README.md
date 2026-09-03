# Ultramarine OS for Xiaomi Pad 6 (pipa)

Ultramarine Linux (Fedora-based) port for the Xiaomi Pad 6, built with the
[Katsu](https://github.com/FyraLabs/katsu) image builder. Packages are
hosted on [pipa-pkgs](https://github.com/thespider2/pipa-pkgs) and pulled
from the remote DNF repo at build time.

## What works

- Display (Freedreno / Mesa)
- Touchscreen (Novatek)
- Audio (AW88261 speaker amplifiers via TDM)
- WiFi and Bluetooth (ath11k / QCA6390)
- Rear camera (OV13B10, fixed-focus, via libcamera + SoftISP)
- Front camera (HI846, via libcamera + SoftISP CPU debayer)
- Sensors (accelerometer, gyroscope, light, proximity via SDSP/libssc)
- USB (host and peripheral)
- Battery and charging

Images ship the full Ultramarine GNOME or Plasma product environment (LibreOffice,
Firefox, Ultramarine branding, and the complete desktop app set) with pipa-specific
hardware support layered on top.

## Repository structure

```
ultramarine-pipa/
├── katsu/              # Katsu image manifests
│   └── modules/ports/pipa/
│       ├── pipa.yaml           # Port module (packages + excludes)
│       ├── pipa-gnome.yaml     # Top-level GNOME disk image manifest
│       ├── pipa-grub-setup.sh  # GRUB configuration script
│       ├── pipa-services.sh    # Service enablement script
│       └── repodir/            # DNF repo pointing to pipa-pkgs
├── scripts/            # Build and flash helper scripts
├── assets/             # EFI template, vbmeta.img
├── Dockerfile          # Fedora 44 build container (Katsu only)
└── output/             # Final flash images (git-ignored)
```

## Package repo

All RPM packages are built and published via
[pipa-pkgs](https://github.com/thespider2/pipa-pkgs) to GitHub Pages:

```
https://thespider2.github.io/pipa-pkgs/repo/ultramarine/
```

This repo only handles image building — it pulls pre-built packages
from the remote DNF repo above.

## Building

### Docker (recommended)

```bash
docker build -t ultramarine-pipa .
docker run --privileged --rm \
  -v "$PWD/output:/build/output" \
  ultramarine-pipa
```

### Local build

```bash
# Requires Fedora 44 (aarch64) with katsu installed
./scripts/build-all.sh
```

## Flashing

Put the device into fastboot mode, then:

```bash
cd output/ultramarine-pipa-gnome-*/

# Single-boot (overwrites Android userdata)
./flash.sh

# Multiboot (flashes to a dedicated "linux" partition)
./flash-multiboot.sh linux boot_ab
```

### Partition mapping

| Image file | Target partition | Contents |
|---|---|---|
| `silicium.img` | `boot_ab` | Mu-Silicium UEFI firmware |
| `ultramarine_esp.raw` | `rawdump` | EFI System Partition |
| `ultramarine_boot.raw` | `cust` | /boot (kernel, initramfs, DTB, GRUB) |
| `ultramarine_rootfs.raw` | `userdata` | Root filesystem |

## First boot

- **GNOME:** GDM runs `gnome-initial-setup` (create your user). Root password is `root` for SSH/recovery.
- **Plasma:** root autologins once (`root` / `root`), shows a create-user dialog, then reboots to the normal login screen.

## OTA Updates

On a running tablet, packages update directly from pipa-pkgs:

```bash
sudo dnf upgrade --refresh
```

## Credits

- Kernel and device tree work based on upstream Linux and Qualcomm SM8250 support
- Mu-Silicium UEFI firmware from [onesaladleaf/Mu-Silicium](https://github.com/onesaladleaf/Mu-Silicium)
- Image build system by [FyraLabs/Katsu](https://github.com/FyraLabs/katsu)
- Arch Linux packaging from [pipa-pkgs](https://github.com/thespider2/pipa-pkgs)
