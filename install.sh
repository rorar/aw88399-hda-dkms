#!/bin/bash
# AW88399 HDA DKMS Install Script
# Installs patched kernel modules, firmware, and UCM2 config for
# Lenovo Legion laptops with Awinic AW88399 smart amplifiers
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER="${1:-$(uname -r)}"
MOD_DIR="/lib/modules/$KVER"

echo "=== AW88399 HDA Sound Fix Installer ==="
echo "Kernel: $KVER"
echo ""

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo $0"
    exit 1
fi

# Step 1: Install firmware
echo "[1/4] Installing firmware..."
if [ -f "$SCRIPT_DIR/firmware/aw88399_acf.bin" ]; then
    cp "$SCRIPT_DIR/firmware/aw88399_acf.bin" /lib/firmware/
    echo "  Installed /lib/firmware/aw88399_acf.bin"
else
    echo "  WARNING: firmware/aw88399_acf.bin not found!"
    echo "  You need to extract it from Windows drivers."
    echo "  Place it at /lib/firmware/aw88399_acf.bin"
fi

# Step 2: Install modules
echo "[2/4] Installing kernel modules..."
DEST="$MOD_DIR/updates/dkms"
mkdir -p "$DEST"

for ko in \
    "$SCRIPT_DIR/realtek/snd-hda-codec-alc269.ko" \
    "$SCRIPT_DIR/soc-codecs/snd-soc-aw88399.ko" \
    "$SCRIPT_DIR/side-codecs/snd-hda-scodec-aw88399.ko" \
    "$SCRIPT_DIR/side-codecs/snd-hda-scodec-aw88399-i2c.ko" \
    "$SCRIPT_DIR/serial-multi-instantiate.ko" \
    "$SCRIPT_DIR/aw88399-setup.ko"
do
    if [ -f "$ko" ]; then
        cp "$ko" "$DEST/"
        echo "  Installed $(basename "$ko")"
    else
        echo "  WARNING: $(basename "$ko") not found - run 'make' first"
    fi
done

depmod -a "$KVER"
echo "  Module dependencies updated"

# Step 3: Configure module loading order
echo "[3/4] Configuring module loading..."
cat > /etc/modprobe.d/aw88399-hda.conf << 'MODCONF'
# AW88399 HDA sound fix for Lenovo Legion
# Blacklist the old snd_soc_aw88399 ACPI binding (we use HDA scodec instead)
# The setup module must load before the HDA I2C driver
softdep snd-hda-scodec-aw88399-i2c pre: aw88399-setup
softdep snd-hda-codec-alc269 pre: snd-hda-scodec-aw88399-i2c
MODCONF
echo "  Created /etc/modprobe.d/aw88399-hda.conf"

# Step 4: Update initramfs
echo "[4/4] Updating initramfs..."
if command -v update-initramfs &>/dev/null; then
    update-initramfs -u -k "$KVER"
elif command -v dracut &>/dev/null; then
    dracut --force --kver "$KVER"
else
    echo "  WARNING: Could not find initramfs update tool"
    echo "  Please update your initramfs manually"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "IMPORTANT: You still need to:"
echo "  1. Ensure /lib/firmware/aw88399_acf.bin exists"
echo "  2. Reboot to load the new modules"
echo ""
echo "After reboot, check with:"
echo "  sudo dmesg | grep -i aw88399"
echo "  lsmod | grep aw88"
echo "  aplay -l"
