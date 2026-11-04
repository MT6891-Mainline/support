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

# --- rootfs tree (systemd units, udev rules, dbus policy, user units) -----
# usr/local/bin is handled above with mode 0755, so it is deliberately excluded
# here; everything else is configuration and stays 0644.
( cd "$HERE/rootfs" || exit 1
  for d in etc usr/lib usr/local/share; do
	[ -d "$d" ] || continue
	find "$d" -type f | while read -r f; do
		mv="/$f"
		install -d "$(dirname "$mv")"
		install -m 0644 "$f" "$mv"
		log "config $mv"
	done
  done )

# --- Denial session -------------------------------------------------------
# Denial is a Flutter Wayland compositor; it replaces the GNOME session this
# repository used to provision.  The package itself comes from Denial's own
# repository, so only check it is there.
if ! command -v denial-session >/dev/null 2>&1; then
	log "WARN: denial-session not found - add Denial's apt repository first:"
	log "       curl -fsSL https://install.denialwm.org | sh && apt install denial"
fi

# The panel tty autologins (no hardware keyboard), so the session starts without
# an authenticated login; --start-locked makes Denial show its own lock screen.
# Denial runs in a seat session this way - started from the serial console it has
# no seat and cannot open the DRM device.
CHOPIN_USER="${CHOPIN_USER:-kily}"
if id "$CHOPIN_USER" >/dev/null 2>&1; then
	home="$(getent passwd "$CHOPIN_USER" | cut -d: -f6)"
	if [ -f "$home/.profile" ] && grep -q denial-session "$home/.profile" 2>/dev/null; then
		log "login profile already starts Denial"
	else
		install -m 0644 "$HERE/rootfs/usr/local/share/chopin/denial-profile" \
			"$home/.profile"
		chown "$CHOPIN_USER:$CHOPIN_USER" "$home/.profile"
		log "installed $home/.profile (starts Denial on tty1)"
	fi
	# the rotation daemon is a user unit; link it into the session target so the
	# user manager starts it without a manual 'systemctl --user enable'
	udir="$home/.config/systemd/user"
	install -d -o "$CHOPIN_USER" -g "$CHOPIN_USER" "$udir"
	install -d -o "$CHOPIN_USER" -g "$CHOPIN_USER" "$udir/denial-session.target.wants"
	ln -sf /usr/lib/systemd/user/chopin-rotator.service \
		"$udir/denial-session.target.wants/chopin-rotator.service"
	chown -h "$CHOPIN_USER:$CHOPIN_USER" \
		"$udir/denial-session.target.wants/chopin-rotator.service"
	log "enabled chopin-rotator for $CHOPIN_USER"
else
	log "WARN: user $CHOPIN_USER does not exist - skipping session profile"
fi

# --- swap -----------------------------------------------------------------
# A graphical session can balloon after repeated restarts - gnome-shell used to
# reach 6 GB and get OOM-killed on this 6.5 GB machine - so keep a swapfile as a
# safety net.
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
	 chopin-gpu-freq chopin-charge-tune chopin-growfs; do
	[ -f "/etc/systemd/system/$u.service" ] && systemctl enable "$u" >/dev/null 2>&1 || true
done
udevadm control --reload >/dev/null 2>&1 || true
# the SensorProxy policy has to be picked up or the proxy cannot own its name and
# nothing (Denial included) sees net.hadess.SensorProxy on the bus
systemctl reload dbus >/dev/null 2>&1 || true
systemctl enable --now chopin-sensorproxy >/dev/null 2>&1 || true
log "services enabled, udev reloaded, dbus policy reloaded"
echo "done - reboot (or 'systemctl start' the units) to pick it all up"
