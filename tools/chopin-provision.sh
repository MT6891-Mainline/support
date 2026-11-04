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

# --- 3d. Denial session ------------------------------------------------------
# Denial owns the input devices (event0/1/2), so the power button is its
# screen-off action; logind must not act on it (HandlePowerKey=ignore).  The
# GNOME-era chopin-powerkey daemon is not part of the Denial branch.
if [ -f "$HERE/denial-session.conf" ]; then
	install -d /etc/denial
	install -m 0644 "$HERE/denial-session.conf" /etc/denial/session.conf
	log "denial session overrides installed"
fi
if [ -f "$HERE/chopin-sensorproxy.conf" ]; then
	install -d /etc/dbus-1/system.d
	install -m 0644 "$HERE/chopin-sensorproxy.conf" \
		/etc/dbus-1/system.d/chopin-sensorproxy.conf
	log "SensorProxy D-Bus policy installed"
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


# GDM must not race the display probe, otherwise mutter reports
# "No GPUs found" and GDM retries in a loop (flashing panel).

# --- 5. Denial session on tty1 ----------------------------------------------
# Denial replaces GDM on this branch: no display manager, no greeter.  The phone
# has no hardware keyboard, so tty1 logs in automatically and the login profile
# starts denial-session --start-locked (Denial then shows its own lock screen).
if id "$SESSION_USER" >/dev/null 2>&1; then
	usermod -aG video,render,input,audio,netdev,bluetooth "$SESSION_USER" 2>/dev/null
	home="$(getent passwd "$SESSION_USER" | cut -d: -f6)"
	if [ -f "$HERE/denial-profile" ]; then
		install -m 0644 "$HERE/denial-profile" "$home/.profile"
		chown "$SESSION_USER:$SESSION_USER" "$home/.profile"
		log "denial login profile for $SESSION_USER"
	fi
	install -d -o "$SESSION_USER" -g "$SESSION_USER" \
		"$home/.config/systemd/user/denial-session.target.wants"
	ln -sf /usr/lib/systemd/user/chopin-rotator.service \
		"$home/.config/systemd/user/denial-session.target.wants/chopin-rotator.service"
	log "chopin-rotator enabled for $SESSION_USER"
fi

# Make sure no display manager fights for seat0 / the tty1 session.
for dm in gdm3 gdm sddm lightdm; do
	systemctl disable "$dm" >/dev/null 2>&1 || true
done

# (No display manager is involved on this branch, so the old GDM/AccountsService
#  X-session workarounds are gone: Denial is started directly from the tty1 login.)

systemctl daemon-reload >/dev/null 2>&1
log "done"
