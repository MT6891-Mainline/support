#!/bin/sh
# Copy the chopin firmware set into this directory from the chopin-firmware
# repository, so install.sh can install it without carrying a second copy here.
#
#   ./fetch.sh                     use ../chopin-firmware (sibling checkout)
#   CHOPIN_FIRMWARE_DIR=... ./fetch.sh   use another checkout
#
# The files are not committed to this repository; the firmware repository is the
# single source of truth (see ../../chopin-firmware/README.md).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=${CHOPIN_FIRMWARE_DIR:-$here/../../chopin-firmware/firmware}

if [ ! -d "$src" ]; then
	echo "fetch.sh: no firmware repository at $src" >&2
	echo "  clone it next to chopin-support, or set CHOPIN_FIRMWARE_DIR" >&2
	exit 1
fi

mkdir -p "$here/mediatek"
cp -f "$src"/*.bin "$here/" 2>/dev/null || true
cp -f "$src"/mediatek/*.bin "$here/mediatek/" 2>/dev/null || true

echo "firmware fetched from $src"
