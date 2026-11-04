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

## Power management

Denial owns idle handling; logind is set to `HandlePowerKey=ignore` and
`IdleAction=ignore` so nothing else fights it.

```json
// ~/.config/denial/settings.json - the state this phone actually runs.
// Denial owns this file: edit it through Settings or the control protocol.
"power": {
  "idleDpmsEnabled": true,
  "idleDpmsTimeoutSeconds": 300,     // blank the panel after 5 min idle
  "idleLockEnabled": true,
  "idleLockTimeoutSeconds": 300,     // lock the session (independent timer)
  "idleSuspendEnabled": false,       // suspend is not usable on this board
  "powerButtonAction": "suspend"     // see below: Denial degrades this to DPMS
}
```

`powerButtonAction` is `suspend` in the saved document, but on this board Denial
does not actually suspend - the log shows what it really does:

```
deniald::dpms: locked the session before power-button display off
deniald::dpms: power button requested compositor-owned display power toggle
deniald::dpms: powered off KMS output through DRM DPMS  output="DSI-1"
```

i.e. a lock plus a DRM DPMS off, and on the next press a fresh frame powers the
output back on.  That is exactly the clean cycle we want, and it is why the power
button neither powers the phone off nor garbles the panel.

Both timers are counted from the last input event and are independent, so set
both if you want "one minute" to mean one minute for locking *and* blanking.
Denial logs every transition:

```
deniald::dpms: locked the session after inactivity
deniald::dpms: powered off KMS output through DRM DPMS  output="DSI-1"
```

The panel comes back with a fresh frame (`queued a fresh frame to power on the
KMS output`), which is why this DPMS cycle does not garble the screen while a
real suspend does.

### Editing settings

`settings.json` is Rust-owned: it validates and rewrites the document, so a hand
edit can be normalized away - a `powerButtonAction` written straight into the file
came back with a different value.  Change settings through Denial Settings or the
control protocol:

```json
{"version":1,"id":1,"method":"settings.document.get"}
{"version":1,"id":2,"method":"settings.document.apply",
 "params":{"expected_revision":30,"document":"{...}"}}
```

## Panel mode and DSI underruns

The panel advertises 1080x2400 at 120/60/50/48/30 Hz.  A handful of DSI buffer
underruns at boot is normal (fbcon taking the panel over).  The kernel only runs
the full ESD recovery when ten underruns land inside two seconds
(`MTK_DSI_UNDERRUN_BURST_LIMIT`), because that recovery re-initialises the panel
behind the compositor's back and used to garble every boot - and with Denial
holding DRM master it left `deniald` stuck in D state, unkillable.

`~/.config/denial/outputs.conf` pins the mode:

```
mode=DSI-1,1080,2400,60000
```

60 Hz halves the DSI bandwidth; 120 Hz works too now that the stray underrun no
longer triggers the recovery.
