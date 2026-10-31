#!/usr/bin/env bash
# Build Image in a way that actually carries the current board DTS.
#
# The kernel does not boot with our own DTB: LK applies the dtbo partition on top
# of whatever tree the boot image carries, and it only accepts the vendor tree.
# So the boot image keeps stock-base.dtb and the kernel swaps in its own tree
# from setup_arch().  That tree is not linked through the normal DTB rules - it
# is .incbin'd from arch/arm64/kernel/chopin-board.dtb:
#
#     arch/arm64/kernel/chopin-dtb.S:
#         .incbin "arch/arm64/kernel/chopin-board.dtb"
#
# and the Makefile only carries
#
#     targets += chopin-board.dtb
#     $(obj)/chopin-dtb.o: $(obj)/chopin-board.dtb
#
# with no rule that rebuilds the .dtb from its .dts.  A stale copy therefore
# survives every `make Image`, silently: the boot image looks fine, the kernel
# boots, and only a device-tree property you edited fails to appear.  That is
# how the mount-matrix change did nothing for two builds in a row.
#
# This script rebuilds the .dtb from source, installs it where .incbin looks,
# drops the object so it is really re-assembled, and then verifies the result by
# extracting the FDT back out of the finished Image.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
src=${SRC:-$top/git/chopin-linux-7.3}
out=${OUT:-$top/build/chopin-7.3}
cross=${CROSS_COMPILE:-aarch64-linux-gnu-}
dtb_src=arch/arm64/boot/dts/mediatek/mt6893-xiaomi-chopin.dtb
board=$out/arch/arm64/kernel/chopin-board.dtb

echo "== building $dtb_src"
make -C "$src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross" \
	mediatek/mt6893-xiaomi-chopin.dtb >/dev/null

echo "== installing it where .incbin looks"
cp -f "$out/$dtb_src" "$board"
rm -f "$out/arch/arm64/kernel/chopin-dtb.o"

echo "== building Image"
make -C "$src" O="$out" ARCH=arm64 CROSS_COMPILE="$cross" -j"$(nproc)" Image >/dev/null

echo "== verifying the embedded tree"
python3 - "$out/arch/arm64/boot/Image" <<'PY'
import struct, subprocess, sys, tempfile, os
raw = open(sys.argv[1], 'rb').read()
i = raw.find(b'\xd0\x0d\xfe\xed')
if i < 0:
    sys.exit("no FDT found inside Image - the swap tree is missing")
size = struct.unpack_from('>I', raw, i + 4)[0]
with tempfile.NamedTemporaryFile(suffix='.dtb', delete=False) as f:
    f.write(raw[i:i + size])
    path = f.name
dts = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', path],
                     capture_output=True, text=True).stdout
os.unlink(path)
print("   embedded FDT: %d bytes at image offset %d" % (size, i))
for probe in ("mount-matrix", "clock-frequency"):
    pass
import re
m = re.search(r'mount-matrix = ([^;]+);', dts)
if m:
    print("   sensor-hub mount-matrix = %s" % m.group(1))
else:
    print("   WARNING: no mount-matrix in the embedded tree")
PY
