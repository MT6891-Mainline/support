#!/bin/sh
# Install the G77-capable Mesa libgallium as the system default.
#
# Debian's aarch64 Mesa has no Mali-G77 backend, so EGL falls back to
# kms_swrast (llvmpipe, software).  The driver built against the same Mesa
# version with G77 support is staged at /root/libgallium-<ver>.so by the
# initramfs; putting it in place makes every EGL client - including KWin -
# use panfrost instead.
#
#   eglinfo | grep "EGL driver name"     kms_swrast  ->  panfrost
#
# Note: this file is owned by libgl1-mesa-dri / mesa-libgallium, so an apt
# upgrade will put the software-only one back.  Hold those packages afterwards.
set -u

LIBDIR=/usr/lib/aarch64-linux-gnu
SRC=$(ls /root/libgallium-*.so 2>/dev/null | head -1)

if [ -z "$SRC" ]; then
	echo "no /root/libgallium-*.so - was GPU_DRIVER passed to build-debian.sh?" >&2
	exit 1
fi

DST=$(ls "$LIBDIR"/libgallium-*.so* 2>/dev/null | grep -v '\.dist$' | head -1)
if [ -z "$DST" ]; then
	echo "no $LIBDIR/libgallium-*.so - is mesa installed?" >&2
	exit 1
fi

echo "staged driver : $SRC"
echo "system driver : $DST"
echo "before        : $(eglinfo 2>/dev/null | grep -m1 'EGL driver name' || echo unknown)"

if [ ! -f "$DST.dist" ]; then
	cp -a "$DST" "$DST.dist" || exit 1
	echo "backup        : $DST.dist"
fi

# Keep the system's exact filename: that is what libEGL/libgbm dlopen.
cp -f "$SRC" "$DST" || exit 1
ldconfig

echo "after         : $(eglinfo 2>/dev/null | grep -m1 'EGL driver name' || echo unknown)"
echo
echo "Pin the packages so an upgrade does not silently restore llvmpipe:"
echo "  apt-mark hold libgl1-mesa-dri mesa-libgallium"
