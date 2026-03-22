#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KVER=${KVER:-$(uname -r)}
KDIR=${KDIR:-/lib/modules/$KVER/build}
M=${M:-$SCRIPT_DIR}

if [ ! -f "$KDIR/Makefile" ]; then
	echo "Kernel build directory not found: $KDIR" >&2
	exit 1
fi

if [ "$#" -eq 0 ]; then
	set -- modules
fi

if [ -z "${LLVM+x}" ] && [ -z "${CC+x}" ] && [ -z "${LD+x}" ]; then
	if grep -qs '^CONFIG_CC_IS_CLANG=y$' "$KDIR/include/config/auto.conf" 2>/dev/null || \
	   grep -qs '^CONFIG_CC_IS_CLANG=y$' "$KDIR/.config" 2>/dev/null; then
		exec make LLVM=1 -C "$KDIR" M="$M" "$@"
	fi
fi

exec make -C "$KDIR" M="$M" "$@"
