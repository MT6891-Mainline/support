#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Package the mainline chopin kernel into an Android boot image that is a
# drop-in replacement for the stock one.
#
# The stock boot_a.img (header version 2) was measured as:
#
#   kernel  13284146 bytes @ 0x40080000   (gzip compressed)
#   ramdisk 57202152 bytes @ 0x51100000
#   tags                   @ 0x47c80000
#   dtb       201848 bytes @ 0x41f78000   (DTBO container -> lk_main_dtb)
#   page size 2048
#
# The addresses below reproduce exactly that layout.
#
# Usage: tools/build-images.sh [out-dir]
#
# Environment:
#   KERNEL / DTB / STOCK_DTB / RAMDISK / CMDLINE
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
port=$(dirname "$here")
ws=$(dirname "$port")

kernel=${KERNEL:-$ws/build/chopin/arch/arm64/boot/Image}
dtb=${DTB:-$ws/build/chopin/arch/arm64/boot/dts/mediatek/mt6893-xiaomi-chopin.dtb}
out=${1:-"$port/out"}
ramdisk=${RAMDISK:-"$out/initramfs.cpio.gz"}
stock_dtb=${STOCK_DTB:-"$out/stock-base.dtb"}

# Regenerate the initramfs rather than trusting whatever is in $out.  A stale
# one cannot be told from a fresh one by looking at it, and that is exactly how
# a ramdisk whose source no longer compiled got packaged: the build was piped
# into a paginator, the pipe reported the paginator's status, and the old
# cpio.gz was reused.  set -e makes this fatal.
"$here/mkinitramfs.sh" "$out" >/dev/null

base=0x40000000
kernel_offset=0x80000
ramdisk_offset=0x11100000
tags_offset=0x7c80000
dtb_offset=0x1f78000
pagesize=2048

cmdline=${CMDLINE:-"bootopt=64S3,32N2,64N2 console=tty0 console=ttyS0,921600n8 earlycon=mtk8250,mmio32,0x11002000 clk_ignore_unused regulator_ignore_unused pd_ignore_unused ignore_loglevel panic=0 printk.devkmsg=on chopinport=ringfix61 cma=256M"}

for f in "$kernel" "$ramdisk"; do
	[ -f "$f" ] || { echo "error: missing $f (run tools/mkinitramfs.sh first)" >&2; exit 1; }
done
[ -f "$dtb" ] || { echo "error: missing $dtb" >&2; exit 1; }
mkdir -p "$out"

# 对齐原厂 Image 头：text_offset = 0x80000（我们的构建产出 0，LK 可能据此算错入口）
python3 - "$kernel" <<'PYEOF'
import struct, sys
path = sys.argv[1]
d = bytearray(open(path, 'rb').read())
if struct.unpack_from('<Q', d, 8)[0] != 0x80000:
    struct.pack_into('<Q', d, 8, 0x80000)
    open(path, 'wb').write(d)
    print("  已修正 text_offset -> 0x80000")
PYEOF

# 内嵌 DTB 的 /chosen/linux,initrd-* 是厂商的陈旧值（那时是 20.7MB 的 ramdisk），
# 而 LK 并不在 FDT 里发布我们这次的范围 —— 内核按陈旧范围解包：先解出我们的
# ramdisk，再继续读后面 ~20MB 垃圾，撞到坏 magic 就报 KERN_EMERG
# "Initramfs unpacking failed: invalid magic..."（/init 仍然能跑，因为该解出的
# 已经解出了）。MTK 自己的构建也按本次 ramdisk 重写这两个属性；这里就地改
# Image 里的内嵌副本（必须在内核被 gzip 之前）。
python3 "$here/fdt-initrd.py" "$kernel" \
	"$(printf '0x%x' $((base + ramdisk_offset)))" "$ramdisk"

if [ "${RAW_KERNEL:-0}" = "1" ]; then
	# 未压缩：绕开 bootloader 解压缓冲区的尺寸限制（我们的 Image 比原厂大 3.6MB）
	cp "$kernel" "$out/Image.gz"
	echo "RAW_KERNEL=1: 使用未压缩 Image ($(stat -c %s "$out/Image.gz") 字节)"
else
	# 必须与原厂 gzip 头一致：FLG=0（不带文件名）、MTIME=0、OS=10。
	# LK 的 gunzip 无法处理 FNAME 可选字段，带文件名的 gzip 会直接
	# "decompress kernel image fail!!!"（实测）。
	gzip -9 -n -c "$kernel" > "$out/Image.gz"
	python3 - "$out/Image.gz" <<'PYEOF'
import sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
if d[0] == 0x1f and d[1] == 0x8b:
    d[3] = 0            # FLG: 无 FNAME/FEXTRA/FCOMMENT
    d[4:8] = b'\0\0\0\0'  # MTIME
    d[9] = 10           # OS: 与原厂一致
    open(p, 'wb').write(d)
PYEOF
fi

pack() { # $1 = dtb, $2 = output name
	mkbootimg \
		--kernel "$out/Image.gz" \
		--ramdisk "$ramdisk" \
		--dtb "$1" \
		--cmdline "$cmdline" \
		--base "$base" \
		--kernel_offset "$kernel_offset" \
		--ramdisk_offset "$ramdisk_offset" \
		--tags_offset "$tags_offset" \
		--dtb_offset "$dtb_offset" \
		--pagesize "$pagesize" \
		--header_version 2 \
		-o "$out/$2"
	echo "$2: $(stat -c %s "$out/$2") bytes"
}

# Our own tree must be wrapped in the same Android DTBO container the stock
# image uses (validated byte-for-byte against the stock container): LK parses
# that container and applies the dtbo partition on top of the base tree inside.
wrapped=${WRAPPED_DTB:-"$out/own-wrapped.dtb"}
"$here/wrap-dtb.py" "$dtb" "$wrapped" >/dev/null

pack "$dtb"      boot-owndtb-rawdtb.img
pack "$wrapped"  boot-owndtb.img

if [ -f "$stock_dtb" ]; then
	pack "$stock_dtb" boot-stockdt.img
"$here/wrap-dtb.py" "$stock_dtb" "$out/stock-wrapped.dtb" >/dev/null
pack "$out/stock-wrapped.dtb" boot-stockdt-wrapped.img
else
	echo "note: $stock_dtb not found, skipping the stock-DT variant"
	echo "      (create it with: tools/extract-stock-dtb.py <stock boot.img> $stock_dtb)"
fi

echo
echo "artifacts in $out:"
ls -l "$out" | sed 's/^/  /'
