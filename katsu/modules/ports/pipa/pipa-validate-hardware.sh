#!/bin/bash
set -eux

assert_file() {
    if [ ! -f "$1" ]; then
        echo "Missing required file: $1" >&2
        exit 1
    fi
}

assert_firmware() {
    if [ -f "$1" ] || [ -f "${1}.xz" ]; then
        return 0
    fi
    echo "Missing required firmware: $1 (or ${1}.xz)" >&2
    exit 1
}

echo "Validating pipa audio configuration..."
if ! rpm -q pipa-sound-conf &>/dev/null; then
    echo "pipa-sound-conf is not installed; audio packages were skipped during image build." >&2
    exit 1
fi
assert_file /usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi\ Pad\ 6.conf
assert_file /usr/share/alsa/ucm2/conf.d/sm8250/sm8250.conf
assert_file /usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi-Pad6-pipa-M82.conf
assert_file /usr/share/alsa/ucm2/Qualcomm/sm8250/HiFi_pipa.conf
assert_file /usr/share/wireplumber/wireplumber.conf.d/51-pipa.conf
assert_file /usr/local/bin/pipa-audio-init
assert_file /usr/lib/systemd/system/pipa-audio-init.service

echo "Validating pipa sensor configuration..."
assert_file /usr/lib/udev/rules.d/81-libssc-xiaomi-pipa.rules
assert_file /usr/local/bin/pipa-prepare-sensor-persist
assert_file /usr/lib/systemd/system/pipa-sensors-persist.service
assert_file /usr/lib/systemd/system/iio-sensor-proxy.service.d/10-pipa-audio.conf
assert_file /usr/lib/systemd/system/pipa-audio-init.service.d/10-sensors.conf

if ! [ -f /usr/lib/libssc.so.0 ] && ! [ -f /usr/lib64/libssc.so.0 ] && \
   ! [ -f /usr/lib/libssc.so.2 ] && ! [ -f /usr/lib64/libssc.so.2 ]; then
    echo "Missing libssc shared library" >&2
    exit 1
fi

echo "Validating critical firmware payloads..."
assert_firmware /usr/lib/firmware/qcom/a650_sqe.fw
assert_firmware /usr/lib/firmware/qcom/a650_gmu.bin
assert_firmware /usr/lib/firmware/qca/htbtfw20.tlv
assert_firmware /usr/lib/firmware/ath11k/QCA6390/hw2.0/amss.bin
assert_firmware /usr/lib/firmware/ath11k/QCA6390/hw2.0/board-2.bin
assert_firmware /usr/lib/firmware/ath11k/QCA6390/hw2.0/m3.bin

assert_file /etc/profile.d/90-pipa-gsk-renderer.sh

if [ -f /etc/gdm/custom.conf ]; then
    echo "Validating GNOME initial setup..."
    rpm -q gnome-initial-setup &>/dev/null || {
        echo "gnome-initial-setup is not installed" >&2
        exit 1
    }
    grep -q '^InitialSetupEnable=True' /etc/gdm/custom.conf || {
        echo "GDM InitialSetupEnable is not True" >&2
        exit 1
    }
    if grep -q '^AutomaticLogin=root' /etc/gdm/custom.conf; then
        echo "GDM still autologins as root instead of gnome-initial-setup" >&2
        exit 1
    fi
    if [ -f /root/.config/autostart/pipa-firstboot-setup.desktop ] \
        || [ -f /var/lib/pipa-firstboot/needs-setup ]; then
        echo "pipa firstboot wizard is still installed for GNOME" >&2
        exit 1
    fi
    if [ ! -x /usr/libexec/gnome-initial-setup ]; then
        echo "gnome-initial-setup binary missing" >&2
        exit 1
    fi
fi

echo "Hardware validation passed."
