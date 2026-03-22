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
echo "[1/6] Installing firmware..."
if [ -f "$SCRIPT_DIR/firmware/aw88399_acf.bin" ]; then
    cp "$SCRIPT_DIR/firmware/aw88399_acf.bin" /lib/firmware/
    echo "  Installed /lib/firmware/aw88399_acf.bin"
else
    echo "  WARNING: firmware/aw88399_acf.bin not found!"
    echo "  You need to extract it from Windows drivers."
    echo "  Place it at /lib/firmware/aw88399_acf.bin"
fi

# Step 2: Install modules
echo "[2/6] Installing kernel modules..."
DEST="$MOD_DIR/updates/dkms"
mkdir -p "$DEST"

find_module() {
    local name

    name="$1"
    for path in \
        "$SCRIPT_DIR/$name.ko" \
        "$SCRIPT_DIR/realtek/$name.ko" \
        "$SCRIPT_DIR/soc-codecs/$name.ko" \
        "$SCRIPT_DIR/side-codecs/$name.ko"
    do
        if [ -f "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done

    return 1
}

for module in \
    snd-hda-codec-alc269 \
    snd-soc-aw88399 \
    snd-hda-scodec-aw88399 \
    snd-hda-scodec-aw88399-i2c \
    serial-multi-instantiate \
    aw88399-setup
do
    if ko="$(find_module "$module")"; then
        cp "$ko" "$DEST/"
        echo "  Installed $(basename "$ko")"
    else
        echo "  WARNING: $module.ko not found - run 'make' first"
    fi
done

depmod -a "$KVER"
echo "  Module dependencies updated"

# Step 3: Configure module loading order
echo "[3/6] Configuring module loading..."
cat > /etc/modprobe.d/aw88399-hda.conf << 'MODCONF'
# AW88399 HDA sound fix for Lenovo Legion
# Blacklist the old snd_soc_aw88399 ACPI binding (we use HDA scodec instead)
# The setup module must load before the HDA I2C driver
softdep snd-hda-scodec-aw88399-i2c pre: aw88399-setup
softdep snd-hda-codec-alc269 pre: snd-hda-scodec-aw88399-i2c
MODCONF
echo "  Created /etc/modprobe.d/aw88399-hda.conf"

# Step 4: Configure bootloader kernel command line
echo "[4/6] Configuring bootloader..."
BOOT_PARAM="snd_intel_dspcfg.dsp_driver=3"

if [ -d /etc/limine-entry-tool.d ] || [ -f /etc/default/limine ]; then
    LIMINE_DIR="/etc/limine-entry-tool.d"
    mkdir -p "$LIMINE_DIR"
    cat > "$LIMINE_DIR/99-aw88399-hda.conf" << EOF
# AW88399 requires SOF DSP driver for I2S clock
KERNEL_CMDLINE[default]+=$BOOT_PARAM
EOF
    echo "  Created $LIMINE_DIR/99-aw88399-hda.conf"

    if command -v limine-update &>/dev/null; then
        limine-update
        echo "  Updated Limine config"
    else
        echo "  WARNING: limine-update not found"
        echo "  Please refresh your Limine config manually"
    fi
elif [ -d /etc/default/grub.d ]; then
    GRUB_DIR="/etc/default/grub.d"
    mkdir -p "$GRUB_DIR"
    cat > "$GRUB_DIR/99-aw88399-hda.cfg" << EOF
# AW88399 requires SOF DSP driver for I2S clock
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $BOOT_PARAM"
EOF
    echo "  Created $GRUB_DIR/99-aw88399-hda.cfg"

    if command -v update-grub &>/dev/null; then
        update-grub
        echo "  Updated GRUB config"
    else
        echo "  WARNING: update-grub not found"
        echo "  Please refresh your GRUB config manually"
    fi
else
    echo "  WARNING: Could not detect Limine or GRUB config directory"
    echo "  Please add '$BOOT_PARAM' to your kernel command line manually"
fi

# Step 5: Install WirePlumber config (SOF DSP broken pipe workaround)
echo "[5/6] Installing WirePlumber config..."
WP_DIR="/usr/share/wireplumber/wireplumber.conf.d"
if [ -d "$(dirname "$WP_DIR")" ]; then
    mkdir -p "$WP_DIR"
    cat > "$WP_DIR/50-aw88399-sof-fix.conf" << 'WPCONF'
# Fix broken pipe / XRUN issue with SOF HDA DSP speaker output
# on Lenovo Legion laptops with AW88399 smart amplifiers.
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.pci-*-platform-skl_hda_dsp_generic.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.period-size   = 2048
        api.alsa.headroom      = 8192
      }
    }
  }
]
WPCONF
    echo "  Created $WP_DIR/50-aw88399-sof-fix.conf"
else
    echo "  WirePlumber not found, skipping"
fi

# Step 6: Update initramfs
echo "[6/6] Updating initramfs..."
if command -v update-initramfs &>/dev/null; then
    update-initramfs -u -k "$KVER"
elif command -v dracut &>/dev/null; then
    dracut --force --kver "$KVER"
elif command -v mkinitcpio &>/dev/null; then
    mkinitcpio -P
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
echo "  sudo ./verify.sh"
