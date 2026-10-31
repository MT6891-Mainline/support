#!/bin/sh
# Extract the MediaTek WiFi/BT blobs this board needs into /lib/firmware.
#
# The kernel asks for them by name and gives up:
#   wlan: Direct firmware load for soc3_0_ram_wmmcu_1a_1_hdr.bin failed (-2)
#   Direct firmware load for mediatek/mt6893/BT_Addr failed (-2)   (x481)
#
# Neither file is in Debian's firmware-mediatek, and neither is on the distro
# rootfs: they live in the vendor's Android partitions.
#
#   WiFi RAM code / ROM patch -> "vendor", a logical partition inside Android's
#       "super".  lpdump says vendor_a starts at sector 13246464 of the super
#       device (/dev/sdc61 here) and is 4428400 sectors long, so a loop device
#       with that byte offset turns the container into a mountable ext4.
#   WiFi NVRAM (calibration) + BT address -> "nvdata".
#
# The stock stack keeps BT_Addr in display order (04:e5:98:..) while the driver
# consumes little-endian bdaddr bytes, hence the byte reversal.
set -u

SUPER=${SUPER:-/dev/sdc61}
VENDOR_OFF=${VENDOR_OFF:-13246464}
NVDATA=${NVDATA:-/dev/sdc6}
FW=/lib/firmware
DEST=$FW/mediatek/mt6893

mkdir -p "$DEST"

echo "== vendor firmware from $SUPER @ sector $VENDOR_OFF"
mkdir -p /mnt/vendor
if LOOP=$(losetup -o $((VENDOR_OFF * 512)) -f --show "$SUPER" 2>/dev/null); then
	echo "   loop $LOOP"
	if mount -o ro "$LOOP" /mnt/vendor 2>/dev/null; then
		if [ -d /mnt/vendor/firmware ]; then
			cp -a /mnt/vendor/firmware/. "$FW/" 2>/dev/null
			echo "   copied $(find /mnt/vendor/firmware -type f | wc -l) files"
		else
			echo "   no /firmware in vendor"
			ls /mnt/vendor | head
		fi
		umount /mnt/vendor
	else
		echo "   mount failed"
	fi
	losetup -d "$LOOP" 2>/dev/null
else
	echo "   losetup failed"
fi

echo "== nvdata: NVRAM + BT address from $NVDATA"
mkdir -p /mnt/nvdata
if mount -o ro "$NVDATA" /mnt/nvdata 2>/dev/null; then
	W=$(find /mnt/nvdata -type f -name WIFI 2>/dev/null | head -1)
	if [ -n "$W" ]; then
		cp "$W" "$DEST/WIFI"
		echo "   WIFI  <- $W ($(stat -c %s "$DEST/WIFI") bytes)"
	fi
	B=$(find /mnt/nvdata -type f -name BT_Addr 2>/dev/null | head -1)
	if [ -n "$B" ]; then
		set -- $(od -An -tx1 -N6 "$B")
		if [ $# -eq 6 ]; then
			printf "\\x$6\\x$5\\x$4\\x$3\\x$2\\x$1" > "$DEST/BT_Addr"
			echo "   BT_Addr <- $B"
			echo "   bdaddr $(od -An -tx1 "$DEST/BT_Addr" | tr -d '\n')"
		fi
	else
		echo "   no BT_Addr under /nvdata (the driver will keep retrying)"
	fi
	umount /mnt/nvdata
else
	echo "   mount failed"
fi

echo "== result"
ls -l "$FW"/soc3_0_ram_wmmcu_1a_1_hdr.bin "$DEST"/WIFI "$DEST"/BT_Addr 2>&1
echo
echo "Now reboot: the WiFi driver gave up after 4 retries and the BT one"
echo "after 481, so they only pick these up on a fresh probe."
