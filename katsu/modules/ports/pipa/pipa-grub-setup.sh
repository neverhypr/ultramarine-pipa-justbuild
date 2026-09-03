#!/bin/bash
set -x

BOOT_LABEL="boot"
CMDLINE="root=LABEL=um-pipa rw rootwait boot=LABEL=${BOOT_LABEL} console=tty0 quiet splash clk_ignore_unused pd_ignore_unused"
INITRAMFS_STABLE="initramfs-linux-pipa.img"

printf '%s\n' "$CMDLINE" > /etc/cmdline
mkdir -p /boot
printf '%s\n' "$CMDLINE" > /boot/cmdline.txt

KERNEL_VER=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)

dracut --force --kver "$KERNEL_VER" "/boot/initramfs-${KERNEL_VER}.img" 2>/dev/null || \
    echo "WARNING: dracut failed, initramfs may need regeneration on first boot"

if [ -f "/boot/initramfs-${KERNEL_VER}.img" ]; then
    cp -f "/boot/initramfs-${KERNEL_VER}.img" "/boot/${INITRAMFS_STABLE}"
fi

mkdir -p /boot/grub /boot/grub2

# Stage 1: rootfs redirect
cat > /boot/grub/grub.cfg <<EOF
search --no-floppy --label --set=boot ${BOOT_LABEL}
set prefix=(\$boot)/grub2
configfile (\$boot)/grub2/grub.cfg
EOF

# Stage 2: boot menu (use pipa-refresh-grub-config when available)
if [ -x /usr/local/bin/pipa-refresh-grub-config ]; then
    PIPA_INITRAMFS_SOURCE="/boot/${INITRAMFS_STABLE}" /usr/local/bin/pipa-refresh-grub-config
else
    kernel_rel="Image"
    [ -f /boot/Image ] || kernel_rel="Image.gz"

    dtb_rels=()
    shopt -s nullglob
    for dtb in /boot/dtbs/qcom/sm8250-xiaomi-pipa*.dtb; do
        dtb_rels+=("${dtb#/boot/}")
    done
    shopt -u nullglob
    [ ${#dtb_rels[@]} -eq 0 ] && dtb_rels=(dtbs/qcom/sm8250-xiaomi-pipa.dtb)

    {
        printf 'set default=0\nset timeout=5\n\n'
        printf 'insmod part_gpt\ninsmod ext2\ninsmod gzio\n\n'
        printf 'search --no-floppy --label %s --set=root\n\n' "$BOOT_LABEL"
        for dtb_rel in "${dtb_rels[@]}"; do
            printf 'menuentry "Ultramarine Linux (Xiaomi Pad 6)" {\n'
            printf '    linux /%s --- %s\n' "$kernel_rel" "$CMDLINE"
            printf '    initrd /%s\n' "$INITRAMFS_STABLE"
            printf '    devicetree /%s\n' "$dtb_rel"
            printf '}\n\n'
        done
    } > /boot/grub2/grub.cfg
fi

rm -f /var/lib/systemd/random-seed
rm -f /etc/NetworkManager/system-connections/*.nmconnection
rm -f /etc/machine-id
touch /etc/machine-id
rm -f /var/lib/rpm/__db*
