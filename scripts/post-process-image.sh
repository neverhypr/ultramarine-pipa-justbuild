#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y%m%d)
VARIANT="${VARIANT_NAME:-gnome}"
IMAGE_NAME="ultramarine-pipa-${VARIANT}-${DATE}"
RAW_IMAGE="${1:-$REPO_ROOT/katsu-work/image/katsu.img}"
OUTPUT_DIR="$REPO_ROOT/output/$IMAGE_NAME"

ROOTFS_LABEL="um-pipa"
BOOT_LABEL="boot"
ESP_LABEL="UMPIPAESP"

SILICIUM_URL="https://github.com/onesaladleaf/Mu-Silicium/releases/download/v3.5-pocketblue/Mu-pipa.img"
VBMETA_IMG="$REPO_ROOT/assets/vbmeta.img"

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root"
    exit 1
fi

if [ ! -f "$RAW_IMAGE" ]; then
    echo "Raw image not found: $RAW_IMAGE"
    echo "Usage: $0 <path-to-katsu-raw-image>"
    exit 1
fi

write_uefi_csv() {
    python3 - "$1" "$2" "$3" "$4" <<'PY'
import pathlib, sys
csv_path, entry_image, title, description = sys.argv[1:5]
text = f"{entry_image},{title},,{description}\r\n"
pathlib.Path(csv_path).write_bytes(b"\xff\xfe" + text.encode("utf-16le"))
PY
}

mkdir -p "$OUTPUT_DIR"
MNT=$(mktemp -d)
BOOT_MNT=$(mktemp -d)
ESP_MNT=$(mktemp -d)
GRUB_ROOT_MNT=""

cleanup() {
    umount "$MNT/boot" 2>/dev/null || true
    umount "$MNT" 2>/dev/null || true
    umount "$BOOT_MNT" 2>/dev/null || true
    umount "$ESP_MNT" 2>/dev/null || true
    if [ -n "${GRUB_ROOT_MNT}" ]; then
        umount "$GRUB_ROOT_MNT/dev/pts" 2>/dev/null || true
        umount "$GRUB_ROOT_MNT/dev" 2>/dev/null || true
        umount "$GRUB_ROOT_MNT/proc" 2>/dev/null || true
        umount "$GRUB_ROOT_MNT/boot" 2>/dev/null || true
        umount "$GRUB_ROOT_MNT" 2>/dev/null || true
        rmdir "$GRUB_ROOT_MNT" 2>/dev/null || true
    fi
    rmdir "$MNT" "$BOOT_MNT" "$ESP_MNT" 2>/dev/null || true
    losetup -j "$RAW_IMAGE" | cut -d: -f1 | xargs -r losetup -d 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Setting up loop device ==="
LOOP=$(losetup --find --show --partscan "$RAW_IMAGE")

ESP_PART="${LOOP}p1"
BOOT_PART="${LOOP}p2"
ROOT_PART="${LOOP}p3"

echo "=== Extracting rootfs ==="
mount "$ROOT_PART" "$MNT"
mkdir -p "$MNT/boot"
mount "$BOOT_PART" "$MNT/boot"

KERNEL_VER=$(find "$MNT/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)
echo "Kernel version: $KERNEL_VER"
echo "Boot contents:"
ls -la "$MNT/boot/" | head -20

SIZE=$(du -sBM "$MNT" | awk '{print $1}' | tr -d 'M')
SIZE=$((SIZE + (SIZE / 8) + 512))
echo "Rootfs size: ${SIZE}M"

truncate -s "${SIZE}M" "$OUTPUT_DIR/ultramarine_rootfs.raw"
MKE2FS_DEVICE_PHYS_SECTSIZE=4096 MKE2FS_DEVICE_SECTSIZE=4096 \
    mkfs.ext4 -L "$ROOTFS_LABEL" "$OUTPUT_DIR/ultramarine_rootfs.raw"
ROOT_MNT=$(mktemp -d)
mount -o loop "$OUTPUT_DIR/ultramarine_rootfs.raw" "$ROOT_MNT"
rsync -aHAX --exclude '/tmp/*' --exclude '/boot/*' --exclude '/boot/efi' "$MNT/" "$ROOT_MNT/"

cat > "$ROOT_MNT/etc/fstab" <<EOF
LABEL=$ROOTFS_LABEL / ext4 defaults,x-systemd.growfs 0 1
LABEL=$BOOT_LABEL /boot ext4 defaults 0 2
EOF

mkdir -p "$ROOT_MNT/boot/grub"
cat > "$ROOT_MNT/boot/grub/grub.cfg" <<EOF
search --no-floppy --label --set=boot $BOOT_LABEL
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF

umount "$ROOT_MNT"
rmdir "$ROOT_MNT"

echo "=== Creating boot image ==="
truncate -s 1024M "$OUTPUT_DIR/ultramarine_boot.raw"
mkfs.ext4 -F -L "$BOOT_LABEL" -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file "$OUTPUT_DIR/ultramarine_boot.raw"
mount -o loop "$OUTPUT_DIR/ultramarine_boot.raw" "$BOOT_MNT"

KERNEL_IMAGE=""
for f in "$MNT/boot/Image.gz" "$MNT/boot/vmlinuz-$KERNEL_VER"; do
    [ -f "$f" ] && KERNEL_IMAGE="$f" && break
done
KERNEL_IMAGE_UNCOMPRESSED=""
for f in "$MNT/boot/Image" "$MNT/boot/vmlinuz-$KERNEL_VER.uncompressed"; do
    [ -f "$f" ] && KERNEL_IMAGE_UNCOMPRESSED="$f" && break
done
INITRAMFS="$MNT/boot/initramfs-$KERNEL_VER.img"
INITRAMFS_STABLE="initramfs-linux-pipa.img"

if [ -z "$KERNEL_IMAGE" ] || [ ! -f "$KERNEL_IMAGE" ]; then
    echo "ERROR: kernel image not found under $MNT/boot" >&2
    ls -la "$MNT/boot/" >&2 || true
    exit 1
fi

cp "$KERNEL_IMAGE" "$BOOT_MNT/Image.gz"
[ -n "$KERNEL_IMAGE_UNCOMPRESSED" ] && [ -f "$KERNEL_IMAGE_UNCOMPRESSED" ] && cp "$KERNEL_IMAGE_UNCOMPRESSED" "$BOOT_MNT/Image"
if [ -f "$INITRAMFS" ]; then
    cp "$INITRAMFS" "$BOOT_MNT/initramfs-$KERNEL_VER.img"
    cp "$INITRAMFS" "$BOOT_MNT/$INITRAMFS_STABLE"
fi

mkdir -p "$BOOT_MNT/dtbs/qcom" "$BOOT_MNT/grub2"
shopt -s nullglob
dtb_files=("$MNT/boot/dtbs/qcom"/sm8250-xiaomi-pipa*.dtb)
shopt -u nullglob
if [ ${#dtb_files[@]} -eq 0 ] && [ -f "$MNT/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb" ]; then
    dtb_files=("$MNT/boot/dtbs/qcom/sm8250-xiaomi-pipa.dtb")
fi
if [ ${#dtb_files[@]} -eq 0 ]; then
    echo "ERROR: no DTB found under $MNT/boot/dtbs/qcom" >&2
    exit 1
fi
cp "${dtb_files[@]}" "$BOOT_MNT/dtbs/qcom/"

[ -f "$MNT/boot/System.map-$KERNEL_VER" ] && cp "$MNT/boot/System.map-$KERNEL_VER" "$BOOT_MNT/"
[ -f "$MNT/boot/config-$KERNEL_VER" ] && cp "$MNT/boot/config-$KERNEL_VER" "$BOOT_MNT/"

TARGET_KERNEL_CMDLINE="root=LABEL=$ROOTFS_LABEL rw rootwait boot=LABEL=$BOOT_LABEL console=tty0 quiet splash clk_ignore_unused pd_ignore_unused"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$BOOT_MNT/cmdline.txt"

umount "$BOOT_MNT"

echo "=== Generating GRUB config (pipa-refresh-grub-config) ==="
GRUB_ROOT_MNT=$(mktemp -d)
mount -o loop "$OUTPUT_DIR/ultramarine_rootfs.raw" "$GRUB_ROOT_MNT"
mkdir -p "$GRUB_ROOT_MNT/boot" "$GRUB_ROOT_MNT/proc" "$GRUB_ROOT_MNT/dev" "$GRUB_ROOT_MNT/dev/pts"
printf '%s\n' "$TARGET_KERNEL_CMDLINE" > "$GRUB_ROOT_MNT/etc/cmdline"
mount -o loop "$OUTPUT_DIR/ultramarine_boot.raw" "$GRUB_ROOT_MNT/boot"
mount -t proc proc "$GRUB_ROOT_MNT/proc"
mount --bind /dev "$GRUB_ROOT_MNT/dev"
mount --bind /dev/pts "$GRUB_ROOT_MNT/dev/pts"
if [ ! -x "$GRUB_ROOT_MNT/usr/local/bin/pipa-refresh-grub-config" ]; then
    echo "ERROR: pipa-refresh-grub-config missing from rootfs" >&2
    exit 1
fi
PIPA_INITRAMFS_SOURCE="/boot/initramfs-$KERNEL_VER.img" \
    chroot "$GRUB_ROOT_MNT" /usr/local/bin/pipa-refresh-grub-config
if [ ! -f "$GRUB_ROOT_MNT/boot/grub2/grub.cfg" ]; then
    echo "ERROR: pipa-grub-config did not generate /boot/grub2/grub.cfg" >&2
    exit 1
fi
umount "$GRUB_ROOT_MNT/dev/pts"
umount "$GRUB_ROOT_MNT/dev"
umount "$GRUB_ROOT_MNT/proc"
umount "$GRUB_ROOT_MNT/boot"
umount "$GRUB_ROOT_MNT"
rmdir "$GRUB_ROOT_MNT"
GRUB_ROOT_MNT=""

BOOT_FS_UUID="$(blkid -s UUID -o value "$OUTPUT_DIR/ultramarine_boot.raw")"
if [ -z "$BOOT_FS_UUID" ]; then
    echo "ERROR: unable to read UUID from ultramarine_boot.raw" >&2
    exit 1
fi

echo "=== Creating ESP image ==="
truncate -s 128M "$OUTPUT_DIR/ultramarine_esp.raw"
mkfs.fat -F 16 -n "$ESP_LABEL" "$OUTPUT_DIR/ultramarine_esp.raw"
mount -o loop "$OUTPUT_DIR/ultramarine_esp.raw" "$ESP_MNT"

# Copy EFI binaries from the Katsu-built image (shim/grub from Fedora packages)
KATSU_ESP_MNT=$(mktemp -d)
if mount "$ESP_PART" "$KATSU_ESP_MNT" 2>/dev/null; then
    if [ -d "$KATSU_ESP_MNT/EFI" ]; then
        cp -r "$KATSU_ESP_MNT/EFI" "$ESP_MNT/"
    fi
    umount "$KATSU_ESP_MNT"
fi
rmdir "$KATSU_ESP_MNT" 2>/dev/null || true

if [ ! -d "$ESP_MNT/EFI/fedora" ]; then
    for efi_src in \
        "$MNT/boot/efi/EFI/fedora" \
        "$MNT/boot/efi/EFI/BOOT" \
        "$MNT/usr/lib/shim" \
        "$MNT/usr/lib/grub/arm64-efi"; do
        [ -d "$efi_src" ] || continue
        mkdir -p "$ESP_MNT/EFI/fedora" "$ESP_MNT/EFI/BOOT"
        for efi_file in shimaa64.efi grubaa64.efi mmaa64.efi; do
            [ -f "$efi_src/$efi_file" ] && cp "$efi_src/$efi_file" "$ESP_MNT/EFI/fedora/"
        done
        [ -f "$ESP_MNT/EFI/fedora/shimaa64.efi" ] || [ -f "$ESP_MNT/EFI/fedora/grubaa64.efi" ] && break
    done
fi

mkdir -p "$ESP_MNT/EFI/fedora" "$ESP_MNT/EFI/BOOT"
if [ -f "$ESP_MNT/EFI/fedora/shimaa64.efi" ]; then
    cp "$ESP_MNT/EFI/fedora/shimaa64.efi" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
elif [ -f "$ESP_MNT/EFI/fedora/grubaa64.efi" ]; then
    cp "$ESP_MNT/EFI/fedora/grubaa64.efi" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
else
    echo "ERROR: No shimaa64.efi or grubaa64.efi found in Katsu image" >&2
    exit 1
fi

# Write shim redirect grub.cfg for each vendor directory
for shim_vendor in fedora BOOT; do
    mkdir -p "$ESP_MNT/EFI/$shim_vendor"
    cat > "$ESP_MNT/EFI/$shim_vendor/grub.cfg" <<ESPCFG
if [ -f \${config_directory}/bootuuid.cfg ]; then
  source \${config_directory}/bootuuid.cfg
fi
if [ -n "\${BOOT_UUID}" ]; then
  search --fs-uuid "\${BOOT_UUID}" --set prefix --no-floppy
else
  search --label $BOOT_LABEL --set prefix --no-floppy
fi
if [ -d (\$prefix)/grub2 ]; then
  set prefix=(\$prefix)/grub2
  configfile \$prefix/grub.cfg
else
  set prefix=(\$prefix)/boot/grub2
  configfile \$prefix/grub.cfg
fi
boot
ESPCFG
    cat > "$ESP_MNT/EFI/$shim_vendor/bootuuid.cfg" <<UUIDCFG
set BOOT_UUID="$BOOT_FS_UUID"
UUIDCFG
done
write_uefi_csv "$ESP_MNT/EFI/fedora/BOOTAA64.CSV" "shimaa64.efi" "Ultramarine" "Ultramarine Pipa"
write_uefi_csv "$ESP_MNT/EFI/BOOT/BOOTAA64.CSV" "BOOTAA64.EFI" "Ultramarine" "Ultramarine Pipa"

umount "$ESP_MNT"
umount "$MNT/boot"
umount "$MNT"

echo "=== Fetching Mu-Silicium ==="
if [ ! -f "$OUTPUT_DIR/silicium.img" ]; then
    wget -O "$OUTPUT_DIR/silicium.img" "$SILICIUM_URL"
fi

echo "=== Copying vbmeta ==="
if [ -f "$VBMETA_IMG" ]; then
    cp "$VBMETA_IMG" "$OUTPUT_DIR/vbmeta.img"
else
    echo "WARNING: vbmeta.img not found at $VBMETA_IMG"
    echo "You'll need to provide this manually"
fi

echo "=== Writing flash scripts ==="
cat > "$OUTPUT_DIR/flash.sh" <<'FLASH'
#!/usr/bin/env bash
set -euo pipefail

echo "### Ultramarine OS - Xiaomi Pad 6 single-boot flasher"
echo "### This flashes Ultramarine rootfs to userdata."
echo

echo "### Verifying connected device..."
fastboot getvar product 2>&1 | grep pipa

read -r -p "Proceed with flashing? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo "### Flashing Mu-Silicium to boot_ab"
fastboot flash boot_ab silicium.img

echo "### Flashing ESP to rawdump"
fastboot flash rawdump ultramarine_esp.raw

echo "### Flashing boot to cust"
fastboot flash cust ultramarine_boot.raw

echo "### Flashing rootfs to userdata"
fastboot flash userdata ultramarine_rootfs.raw

echo "### Rebooting..."
fastboot reboot
FLASH
chmod +x "$OUTPUT_DIR/flash.sh"

cat > "$OUTPUT_DIR/flash-multiboot.sh" <<'MFLASH'
#!/usr/bin/env bash
set -euo pipefail

echo "### Ultramarine OS - Xiaomi Pad 6 multiboot flasher"
echo "### This flashes rootfs to a dedicated partition."
echo

ROOTFS_PART="${1:-linux}"
BOOT_SLOT="${2:-boot_ab}"

echo "### Verifying connected device..."
fastboot getvar product 2>&1 | grep pipa

echo "Flash plan:"
echo "  Mu-Silicium  -> $BOOT_SLOT"
echo "  ESP          -> rawdump"
echo "  boot         -> cust"
echo "  rootfs       -> $ROOTFS_PART"
echo

read -r -p "Proceed? [Y/n]: " CONFIRM
case "${CONFIRM:-Y}" in
    y|Y|yes|YES|"") ;;
    *) echo "Aborted."; exit 0 ;;
esac

fastboot flash "$BOOT_SLOT" silicium.img
fastboot flash rawdump ultramarine_esp.raw
fastboot flash cust ultramarine_boot.raw
fastboot flash "$ROOTFS_PART" ultramarine_rootfs.raw

echo "### Rebooting..."
fastboot reboot
MFLASH
chmod +x "$OUTPUT_DIR/flash-multiboot.sh"

echo "=== Writing build metadata ==="
cat > "$OUTPUT_DIR/BUILDINFO.txt" <<EOF
Ultramarine OS Pipa Image Build
================================
Desktop:        ${VARIANT}
Build date:     $DATE
Kernel:         ${KERNEL_VER:-unknown}
Rootfs label:   $ROOTFS_LABEL
Boot label:     $BOOT_LABEL
ESP label:      $ESP_LABEL
Silicium URL:   $SILICIUM_URL
EOF

echo "=== Generating checksums ==="
(cd "$OUTPUT_DIR" && sha256sum -- *.raw *.img *.sh BUILDINFO.txt > SHA256SUMS)

echo "=== Creating ZIP archive ==="
(cd "$OUTPUT_DIR" && zip -r "../$IMAGE_NAME.zip" .)

echo ""
echo "=== Done! ==="
echo "Output: $OUTPUT_DIR/"
echo "ZIP:    $REPO_ROOT/output/$IMAGE_NAME.zip"
