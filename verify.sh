#!/bin/bash
# Post-boot verification for the AW88399 HDA sound fix
set -u

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
    printf '[PASS] %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
    printf '[WARN] %s\n' "$1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

section() {
    printf '\n== %s ==\n' "$1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

module_to_sys_name() {
    printf '%s\n' "$1" | tr '-' '_'
}

module_file_path() {
    local name path

    name="$1"
    for path in \
        "/lib/modules/$KVER/updates/dkms/$name.ko" \
        "/lib/modules/$KVER/updates/dkms/$name.ko.zst" \
        "/lib/modules/$KVER/extra/$name.ko" \
        "/lib/modules/$KVER/extra/$name.ko.zst"
    do
        if [ -f "$path" ]; then
            printf '%s\n' "$path"
            return 0
        fi
    done

    return 1
}

KVER="$(uname -r)"
CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
BOOT_PARAM="snd_intel_dspcfg.dsp_driver=3"
DSP_DRIVER_PATH="/sys/module/snd_intel_dspcfg/parameters/dsp_driver"

REQUIRED_MODULES=(
    snd-hda-codec-alc269
    snd-soc-aw88399
    snd-hda-scodec-aw88399
    snd-hda-scodec-aw88399-i2c
    aw88399-setup
)

STALE_CONFS=(
    /etc/modprobe.d/alc287.conf
    /etc/modprobe.d/lenovo-audio.conf
)

section "Kernel"
printf 'Running kernel: %s\n' "$KVER"

if printf '%s\n' "$CMDLINE" | grep -qw "$BOOT_PARAM"; then
    pass "Kernel cmdline contains $BOOT_PARAM"
else
    fail "Kernel cmdline is missing $BOOT_PARAM"
fi

if [ -r "$DSP_DRIVER_PATH" ]; then
    DSP_DRIVER_VALUE="$(cat "$DSP_DRIVER_PATH")"
    printf 'snd_intel_dspcfg.dsp_driver=%s\n' "$DSP_DRIVER_VALUE"
    if [ "$DSP_DRIVER_VALUE" = "3" ]; then
        pass "SOF DSP driver mode is active"
    else
        fail "SOF DSP driver mode is not 3"
    fi
else
    fail "Could not read $DSP_DRIVER_PATH"
fi

section "Files"
if [ -f /lib/firmware/aw88399_acf.bin ]; then
    pass "Firmware is installed at /lib/firmware/aw88399_acf.bin"
else
    fail "Firmware file /lib/firmware/aw88399_acf.bin is missing"
fi

if [ -f /etc/modprobe.d/aw88399-hda.conf ]; then
    pass "Found /etc/modprobe.d/aw88399-hda.conf"
else
    fail "Missing /etc/modprobe.d/aw88399-hda.conf"
fi

if [ -f /etc/limine-entry-tool.d/99-aw88399-hda.conf ]; then
    pass "Found Limine drop-in /etc/limine-entry-tool.d/99-aw88399-hda.conf"
elif [ -f /etc/default/grub.d/99-aw88399-hda.cfg ]; then
    pass "Found GRUB drop-in /etc/default/grub.d/99-aw88399-hda.cfg"
else
    warn "No AW88399 bootloader drop-in was found"
fi

for conf in "${STALE_CONFS[@]}"; do
    if [ -f "$conf" ]; then
        warn "Obsolete audio override still present: $conf"
    fi
done

for module in "${REQUIRED_MODULES[@]}"; do
    if path="$(module_file_path "$module")"; then
        pass "Installed module file found: $path"
    else
        fail "Installed module file not found for $module"
    fi
done

section "Modules"
for module in "${REQUIRED_MODULES[@]}"; do
    sys_name="$(module_to_sys_name "$module")"
    if [ -d "/sys/module/$sys_name" ]; then
        pass "Module loaded: $sys_name"
    else
        warn "Module not currently loaded: $sys_name"
    fi
done

if have_cmd lsmod; then
    printf '\nLoaded module snapshot:\n'
    lsmod | grep -E 'aw88|snd_hda_scodec_aw88399|snd_soc_aw88399|snd_hda_codec_alc269' || true
fi

section "Audio"
if have_cmd aplay; then
    APLAY_OUTPUT="$(aplay -l 2>&1 || true)"
    printf '%s\n' "$APLAY_OUTPUT"
    if printf '%s\n' "$APLAY_OUTPUT" | grep -Eq 'ALC287|ALC28|sof|HDA'; then
        pass "aplay reports an audio device"
    else
        warn "aplay output does not clearly show the expected audio device"
    fi
else
    warn "aplay is not installed"
fi

section "Kernel Log"
if have_cmd dmesg; then
    DMESG_OUTPUT="$(dmesg 2>&1 | grep -iE 'aw88399|AWDZ8399|aw88399_setup' || true)"
    if [ -n "$DMESG_OUTPUT" ]; then
        printf '%s\n' "$DMESG_OUTPUT"
        pass "Kernel log contains AW88399 messages"
        if printf '%s\n' "$DMESG_OUTPUT" | grep -qiE 'error|fail|timeout'; then
            warn "Kernel log includes AW88399 error-like messages"
        fi
    else
        if dmesg >/dev/null 2>&1; then
            warn "No AW88399 messages were found in dmesg"
        else
            warn "Could not read dmesg; rerun with sudo for full verification"
        fi
    fi
else
    warn "dmesg is not available"
fi

section "Summary"
printf 'PASS: %d\n' "$PASS_COUNT"
printf 'WARN: %d\n' "$WARN_COUNT"
printf 'FAIL: %d\n' "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
