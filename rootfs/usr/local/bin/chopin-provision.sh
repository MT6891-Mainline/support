#!/bin/sh
# Apply the chopin userspace configuration to a Debian rootfs.
#
# Idempotent: safe to re-run.  Run as root, either inside the build container
# (chroot into the rootfs) or directly on the device.
set -u

HERE=$(dirname "$0")
SESSION_USER=${SESSION_USER:-kily}
SENSOR_HUB=/sys/bus/iio/devices/iio:device1

log() { printf '  %s\n' "$*"; }

# --- 1. sensor helpers ------------------------------------------------------
for f in chopin-scp-start setup-iio-trigger chopin-sensorproxy; do
	src=""
	for cand in "$HERE/$f.sh" "$HERE/$f" "$HERE/$f.py"; do
		[ -f "$cand" ] && { src="$cand"; break; }
	done
	[ -n "$src" ] || { log "missing $f"; continue; }
	install -m 0755 "$src" "/usr/local/bin/$f"
	log "installed /usr/local/bin/$f"
done

# --- 2. systemd units -------------------------------------------------------
cat > /etc/systemd/system/chopin-scp.service <<'U'
[Unit]
Description=Start the SCP core (chopin sensors)
Before=chopin-iio-trigger.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/chopin-scp-start

[Install]
WantedBy=multi-user.target
U

cat > /etc/systemd/system/chopin-iio-trigger.service <<'U'
[Unit]
Description=Bind an hrtimer trigger to the chopin accelerometer
After=chopin-scp.service local-fs.target
Requires=chopin-scp.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/setup-iio-trigger

[Install]
WantedBy=multi-user.target
U

cat > /etc/systemd/system/chopin-sensorproxy.service <<'U'
[Unit]
Description=net.hadess.SensorProxy for chopin (replaces iio-sensor-proxy 3.7)
After=chopin-scp.service chopin-iio-trigger.service
Wants=chopin-scp.service

[Service]
ExecStart=/usr/local/bin/chopin-sensorproxy
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
U

# NOTE: never add "ExecStartPost=systemctl restart ..." to the oneshot units
# above.  A oneshot restarting another unit from its own ExecStartPost
# deadlocks against the transaction that started it, multi-user.target never
# finishes and serial-getty@ttyGS0 stays inactive ("serial has no login").

# --- 3. services ------------------------------------------------------------
systemctl enable chopin-scp.service chopin-iio-trigger.service \
	chopin-sensorproxy.service >/dev/null 2>&1
# iio-sensor-proxy 3.7 cannot drive this board (no usable trigger, buffer only).
systemctl disable iio-sensor-proxy.service >/dev/null 2>&1
log "sensor services enabled"

# --- 3b. GPU core clock (opt-in) -------------------------------------------
# The knob retunes mfgpll safely; the service is a no-op until
# /etc/chopin-gpu-freq exists (see port/GPU-PERF.md §9).
for f in chopin-gpu-freq; do
	src=""
	for cand in "$HERE/$f.sh" "$HERE/$f"; do
		[ -f "$cand" ] && { src="$cand"; break; }
	done
	[ -n "$src" ] && install -m 0755 "$src" "/usr/local/bin/$f"
done
if [ -f "$HERE/chopin-gpu-freq.service" ]; then
	install -m 0644 "$HERE/chopin-gpu-freq.service" \
		/etc/systemd/system/chopin-gpu-freq.service
	systemctl enable chopin-gpu-freq.service >/dev/null 2>&1
	log "GPU clock service installed (inactive until /etc/chopin-gpu-freq)"
fi

# --- 3c. charging current --------------------------------------------------
# The MT6360 comes up with the SDP default (500 mA in, 500 mA charge) which
# leaves ~85 mA for the battery; the service raises it to 900 mA on a plain USB
# port and 2 A on a dedicated charger.  See port/CHARGING.md.
if [ -f "$HERE/chopin-charge-tune.sh" ]; then
	install -m 0755 "$HERE/chopin-charge-tune.sh" \
		/usr/local/bin/chopin-charge-tune.sh
fi
if [ -f "$HERE/chopin-charge-tune.service" ]; then
	install -m 0644 "$HERE/chopin-charge-tune.service" \
		/etc/systemd/system/chopin-charge-tune.service
	systemctl enable chopin-charge-tune.service >/dev/null 2>&1
	log "charging current service installed"
fi
if [ -f "$HERE/99-chopin-charge.rules" ]; then
	install -d /etc/udev/rules.d
	install -m 0644 "$HERE/99-chopin-charge.rules" \
		/etc/udev/rules.d/99-chopin-charge.rules
	log "charging udev rule installed"
fi

# --- 4. no suspend, no idle blank ------------------------------------------
mkdir -p /etc/systemd/logind.conf.d
install -m 0644 "$HERE/logind-no-suspend.conf" \
	/etc/systemd/logind.conf.d/10-chopin-no-suspend.conf

# Suspend cannot work here (see the .desktop comment), so hold an inhibitor
# from inside the session rather than trying to fix suspend.
install -d /etc/xdg/autostart
install -m 0644 "$HERE/chopin-no-suspend.desktop" \
	/etc/xdg/autostart/chopin-no-suspend.desktop

# GDM must not race the display probe, otherwise mutter reports
# "No GPUs found" and GDM retries in a loop (flashing panel).
install -d /etc/systemd/system/gdm.service.d
install -m 0644 "$HERE/gdm-wait-for-dsi.conf" \
	/etc/systemd/system/gdm.service.d/10-wait-for-dsi.conf

# System-wide dconf defaults so the settings also apply before the first login.
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
install -m 0644 "$HERE/dconf/00-chopin" /etc/dconf/db/local.d/00-chopin
install -m 0644 "$HERE/dconf/user" /etc/dconf/profile/user
command -v dconf >/dev/null 2>&1 && dconf update >/dev/null 2>&1
log "logind + dconf defaults installed"

# --- 5. display manager: gdm with autologin ---------------------------------
if [ -f /usr/lib/systemd/system/gdm.service ] || [ -f /lib/systemd/system/gdm.service ]; then
	id "$SESSION_USER" >/dev/null 2>&1 || {
		log "no user $SESSION_USER, skipping autologin"; }
	if id "$SESSION_USER" >/dev/null 2>&1; then
		# DRM/input/GPU access for the session user.
		usermod -aG video,render,input,audio,netdev,bluetooth \
			"$SESSION_USER" 2>/dev/null
		mkdir -p /etc/gdm3
		# GDM refuses AutomaticLogin=root ("user != root" in gdm-autologin),
		# and its greeter cannot start here: /run/user/108 has no user
		# manager, and the X11 fallback dies with "Cannot run in framebuffer
		# mode".  Autologin is therefore the only way in.
		cat > /etc/gdm3/daemon.conf <<G
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$SESSION_USER
WaylandEnable=true
G
		log "autologin $SESSION_USER"
	fi
fi

# The display-manager.service symlink is a Debian "alternative": purging sddm
# deletes it, and nothing re-creates it when GDM is installed non-interactively.
# Without it the machine boots to a black screen with no session at all.
if [ -f /usr/lib/systemd/system/gdm.service ]; then
	ln -sf /usr/lib/systemd/system/gdm.service \
		/etc/systemd/system/display-manager.service
	printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager
	systemctl disable sddm.service >/dev/null 2>&1
	log "display-manager -> gdm"
fi

# X sessions cannot start on this board - Xorg dies with "Cannot run in
# framebuffer mode" - and GDM picks the session recorded in AccountsService.
# A stale "Session=gnome-xorg" (easy to get: run gnome-shell --nested with
# DISPLAY set, and AccountsService remembers the X session) makes GDM try the X
# session, the session never registers and autologin looks broken on every
# boot after that.  Hide the X sessions so only Wayland can be chosen, and
# repoint a stale recording.
if [ -f /usr/share/xsessions/gnome-xorg.desktop ]; then
	install -d /usr/local/share/xsessions-disabled
	mv /usr/share/xsessions/gnome-xorg.desktop \
		/usr/local/share/xsessions-disabled/ 2>/dev/null
	log "X session disabled (Xorg cannot start here)"
fi

acct=/var/lib/AccountsService/users/$SESSION_USER
if [ -f "$acct" ] && grep -q '^Session=.*xorg' "$acct"; then
	sed 's/^Session=.*/Session=gnome/' "$acct" > /tmp/.acct.$$ &&
		cat /tmp/.acct.$$ > "$acct"
	rm -f /tmp/.acct.$$
	log "AccountsService session pinned to gnome (Wayland)"
fi

systemctl daemon-reload >/dev/null 2>&1
log "done"
