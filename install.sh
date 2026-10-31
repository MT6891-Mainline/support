#!/bin/sh
# chopin-support: install everything this repository carries into the running
# rootfs.  Idempotent - safe to re-run after adding files.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

log() { printf '  %s\n' "$*"; }

# --- firmware -------------------------------------------------------------
install -d /lib/firmware/mediatek
install -m 0644 "$HERE/firmware/mali_csffw.bin" /lib/firmware/mali_csffw.bin
for f in "$HERE"/firmware/mediatek/*.bin; do
	[ -e "$f" ] || continue
	install -m 0644 "$f" "/lib/firmware/mediatek/$(basename "$f")"
done
log "firmware installed (mali + mediatek wifi)"

# --- user scripts ---------------------------------------------------------
for f in "$HERE"/rootfs/usr/local/bin/*; do
	[ -e "$f" ] || continue
	install -m 0755 "$f" "/usr/local/bin/$(basename "$f")"
	log "script $(basename "$f")"
done

# --- rootfs tree (systemd units, udev, dconf, autostart, defaults) --------
( cd "$HERE/rootfs" && find etc -type f | while read -r f; do
	mv="/$f"
	install -d "$(dirname "$mv")"
	install -m 0644 "$f" "$mv"
	log "config $mv"
done )

# --- swap -----------------------------------------------------------------
# gnome-shell can balloon to several gigabytes after repeated session restarts
# (the OOM killer shot it down once: "anon-rss:6086184kB" on a 6.5 GB machine),
# so keep a swapfile as a safety net.
if [ ! -e /swapfile ] && [ "$(id -u)" = 0 ]; then
	fallocate -l 4G /swapfile 2>/dev/null || \
		dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
	chmod 600 /swapfile
	mkswap /swapfile >/dev/null
	swapon /swapfile
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
	log "4 GB swapfile created"
fi

# --- activate -------------------------------------------------------------
systemctl daemon-reload
for u in chopin-scp chopin-iio-trigger chopin-sensorproxy \
	 chopin-gpu-freq chopin-charge-tune chopin-growfs chopin-powerkey; do
	[ -f "/etc/systemd/system/$u.service" ] && systemctl enable "$u" >/dev/null 2>&1 || true
done
udevadm control --reload >/dev/null 2>&1 || true
dconf update >/dev/null 2>&1 || true
log "services enabled, udev reloaded, dconf updated"
echo "done - reboot (or 'systemctl start' the units) to pick it all up"
