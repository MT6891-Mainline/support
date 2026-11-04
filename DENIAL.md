# Denial branch

This branch replaces the GNOME session with **Denial**
(<https://github.com/denialwm/denial>), a Flutter Wayland compositor, and carries
everything the phone needs to run it.

## What changed relative to `main` (the GNOME branch)

| Removed (GNOME) | Added (Denial) |
| --- | --- |
| `etc/dconf/db/local.d/00-chopin` (idle blank, lock, power action) | `etc/denial/session.conf` (`DENIAL_SHELL_PROFILE=mobile`, DRM/render split) |
| `etc/systemd/system/gdm.service.d/10-wait-for-dsi.conf` | `etc/systemd/system/getty@tty1.service.d/autologin.conf` |
| `usr/local/bin/chopin-powerkey` + service | `usr/local/bin/chopin-rotator` + `usr/lib/systemd/user/chopin-rotator.service` |
| `usr/local/bin/chopin-rotate` (KWin) | `usr/local/share/chopin/denial-profile` (starts `denial-session --start-locked`) |
| `etc/xdg/autostart/chopin-autorotate.desktop` | `etc/dbus-1/system.d/chopin-sensorproxy.conf` |

Kept: firmware, GPU clock (`chopin-gpu-freq`), charging (`chopin-charge-tune`),
Sensors/SCP (`chopin-scp`, `chopin-iio-trigger`), `chopin-sensorproxy`,
`chopin-growfs`, udev rules, logind `HandlePowerKey=ignore` (Denial owns the
power button now).

## Session start

The phone has no hardware keyboard, so tty1 autologins and the login profile
runs:

```sh
exec denial-session --start-locked > ~/denial.log 2>&1
```

* `--start-locked` is required because autologin bypasses authentication -
  Denial shows its own lock screen first.
* It must run in a **seat session** (tty1). Started from the serial console
  (ttyGS0, no seat) Denial cannot open the DRM device:
  `Failed to open device: Resource temporarily unavailable`.

## Auto rotation

Denial has no accelerometer source; its "auto rotate" toggle is only a flag
(`settings.rotationLock.enabled`). `chopin-rotator` does the work and obeys that
flag:

```
accelerometer (/sys/bus/iio/devices/iio:device1)
  -> chopin-rotator        (user unit, wanted by denial-session.target)
  -> Denial control socket  outputs.apply transform=normal|90|180|270
```

Transform-only changes do not trigger a modeset and reuse the buffer pool
(control protocol v1), so rotation is cheap.

`chopin-sensorproxy` publishes `net.hadess.SensorProxy`; the D-Bus policy in
`etc/dbus-1/system.d/chopin-sensorproxy.conf` is required or the name cannot be
claimed and no client sees the sensor.

## Audio

Denial talks PulseAudio through **libpulse**, so the session needs a
PulseAudio-compatible server; Debian 13's PipeWire with `pipewire-pulse` is it:

```sh
apt-get install -y pipewire pipewire-pulse wireplumber pulseaudio-utils alsa-utils
# per session user:
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
```

The codec (`mt6893_mt6359`, card 0) has **no UCM profile**, so WirePlumber exposes
its plain stereo output (`alsa_output.platform-sound.stereo-fallback`). That is
the only playback path this board has; sound works through it.

Denial connects to it on start:

```
deniald::system_controls::audio: Denial Rust audio connected through native libpulse
```

and its volume keys / quick-panel volume slider drive that sink.

## Bluetooth

Already handled by `btmtk` + BlueZ; nothing board-specific to configure. The only
change is keeping the adapter powered without a manual `bluetoothctl power on`:

```
# /etc/bluetooth/main.conf
AutoEnable=true
```

```sh
systemctl enable --now bluetooth
```

Denial's quick panel talks to BlueZ over the system bus for the power toggle.
