#!/bin/sh
# Bind an hrtimer trigger to chopin-accel so IIO buffer reads work.
#
# Needed because Debian 13's iio-sensor-proxy (3.7) only supports accelerometers
# through the IIO buffer, and this kernel shipped with no trigger at all
# (CONFIG_IIO_HRTIMER_TRIGGER was off).  Without it the proxy prints
#   "No sensors or missing kernel drivers for the sensors"
# and exits, so nothing (GNOME, Plasma, ...) ever sees an orientation.
#
# v124 enables IIO_HRTIMER_TRIGGER, which pulls in IIO_SW_TRIGGER ->
# IIO_CONFIGFS -> CONFIGFS_FS.
set -u
IIO=/sys/bus/iio/devices/iio:device1
NAME=chopin

[ -d "$IIO" ] || { echo "no $IIO (is the SCP started?)"; exit 1; }

# configfs may not be mounted yet on a minimal system.
if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
	mount -t configfs none /sys/kernel/config 2>/dev/null
fi
TRIG=/sys/kernel/config/iio/triggers/hrtimer
if [ ! -d "$TRIG" ]; then
	echo "no $TRIG - is CONFIG_IIO_HRTIMER_TRIGGER in this kernel?"
	exit 1
fi

[ -d "$TRIG/$NAME" ] || mkdir -p "$TRIG/$NAME" || exit 1

# Rebinding the same trigger is harmless.
echo "$NAME" > "$IIO/trigger/current_trigger" || {
	echo "cannot bind $NAME to $IIO"
	exit 1
}

echo 100 > "$IIO/sampling_frequency" 2>/dev/null
echo "trigger bound: $(cat "$IIO/trigger/current_trigger")"

# Wake the buffer up once so the proxy finds data on its first read.
echo 1 > "$IIO/buffer/enable" 2>/dev/null
sleep 0.2
echo 0 > "$IIO/buffer/enable" 2>/dev/null
