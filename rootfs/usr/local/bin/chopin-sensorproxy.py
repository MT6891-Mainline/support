#!/usr/bin/python3
"""Minimal net.hadess.SensorProxy implementation for chopin.

Debian 13 ships iio-sensor-proxy 3.7, which only supports accelerometers through
the IIO buffer and then gives up on this board:

    Could not find trigger name associated with .../iio:device1
    Buffer '/dev/iio:device1' did not have data within 0.5s

so nothing ever gets an orientation and GNOME's auto-rotation stays dead.

Rather than fight that version, publish the same D-Bus interface ourselves.  The
orientation is computed the same way as chopin-rotate does it (raw frame, no
mount matrix: the SCP firmware already rotated the axes), and consumers cannot
tell the difference - GNOME's gsd-orientation plugin and Plasma both only need
this interface.

Properties are emitted as PropertiesChanged when the orientation changes.
"""
import os
import sys
import time

import gi

gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

IIO = "/sys/bus/iio/devices/iio:device1"
BUS_NAME = "net.hadess.SensorProxy"
OBJ_PATH = "/net/hadess/SensorProxy"
POLL_US = 200 * 1000
FLAT_G = 7.0
DOMINANCE = 1.6

NODE = """
<node>
  <interface name="net.hadess.SensorProxy">
    <method name="ClaimAccelerometer"/>
    <method name="ReleaseAccelerometer"/>
    <method name="ClaimLight"/>
    <method name="ReleaseLight"/>
    <method name="ClaimProximity"/>
    <method name="ReleaseProximity"/>
    <method name="ClaimCompass"/>
    <method name="ReleaseCompass"/>
    <property name="HasAccelerometer" type="b" access="read"/>
    <property name="AccelerometerOrientation" type="s" access="read"/>
    <property name="HasAmbientLight" type="b" access="read"/>
    <property name="LightLevel" type="d" access="read"/>
    <property name="HasProximity" type="b" access="read"/>
    <property name="ProximityNear" type="b" access="read"/>
    <property name="HasCompass" type="b" access="read"/>
    <property name="CompassHeading" type="d" access="read"/>
  </interface>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="out"/>
    </method>
    <method name="GetAll">
      <arg type="s" direction="in"/>
      <arg type="a{sv}" direction="out"/>
    </method>
    <method name="Set">
      <arg type="s" direction="in"/><arg type="s" direction="in"/>
      <arg type="v" direction="in"/>
    </method>
    <signal name="PropertiesChanged">
      <arg type="s"/><arg type="a{sv}"/><arg type="as"/>
    </signal>
  </interface>
</node>
"""


def rd(name, tries=40):
    last = None
    for _ in range(tries):
        try:
            with open(os.path.join(IIO, name)) as f:
                return f.read().strip()
        except (OSError, TypeError) as e:   # -EAGAIN until the ring has a sample
            last = e
            time.sleep(0.05)
    raise last


def orientation():
    scale = float(rd("in_accel_scale"))
    x, y, z = (int(rd("in_accel_%s_raw" % c)) * scale for c in "xyz")
    if abs(z) > FLAT_G:
        return None                      # flat: keep the last orientation
    if abs(y) > DOMINANCE * abs(x):
        return "normal" if y > 0 else "bottom-up"
    if abs(x) > DOMINANCE * abs(y):
        return "right-up" if x > 0 else "left-up"
    return None                          # ambiguous: don't flap


class Proxy:
    def __init__(self):
        # Start at "normal" rather than "undefined": a phone resting flat
        # reports no dominant axis, and "undefined" would make consumers
        # skip rotation until the first tilt.
        self.orientation = "normal"
        self.light = 0.0

    def props(self):
        return {
            "HasAccelerometer": GLib.Variant("b", True),
            "AccelerometerOrientation": GLib.Variant("s", self.orientation),
            "HasAmbientLight": GLib.Variant("b", False),
            "LightLevel": GLib.Variant("d", self.light),
            "HasProximity": GLib.Variant("b", False),
            "ProximityNear": GLib.Variant("b", False),
            "HasCompass": GLib.Variant("b", False),
            "CompassHeading": GLib.Variant("d", 0.0),
        }


def main():
    node = Gio.DBusNodeInfo.new_for_xml(NODE)
    proxy = Proxy()
    loop = GLib.MainLoop()

    def on_call(conn, sender, path, iface, method, params, invocation):
        if iface == "org.freedesktop.DBus.Properties":
            if method == "Get":
                # Properties.Get takes (interface_name, property_name)
                args = params.unpack()
                name = args[1] if len(args) == 2 else args[0]
                all_props = proxy.props()
                if name in all_props:
                    invocation.return_value(GLib.Variant("(v)", (all_props[name],)))
                else:
                    invocation.return_dbus_error(
                        "org.freedesktop.DBus.Error.UnknownProperty", name)
                return
            if method == "GetAll":
                invocation.return_value(GLib.Variant("(a{sv})", (proxy.props(),)))
                return
            if method == "Set":
                invocation.return_value(None)     # read-only, accept silently
                return
        # Claim*/Release*: nothing to do, we always sample.
        invocation.return_value(None)

    conn = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    conn.register_object(OBJ_PATH, node.interfaces[0], on_call, None, None)
    conn.register_object(OBJ_PATH, node.interfaces[1], on_call, None, None)

    Gio.bus_own_name_on_connection(conn, BUS_NAME,
                                   Gio.BusNameOwnerFlags.NONE, None, None)

    last = {"v": None}

    def tick():
        try:
            o = orientation()
        except (OSError, TypeError):
            return True                        # sensor not streaming yet
        if o is None or o == last["v"]:
            return True
        proxy.orientation = o
        last["v"] = o
        print("orientation %s" % o, flush=True)
        conn.emit_signal(None, OBJ_PATH, "org.freedesktop.DBus.Properties",
                         "PropertiesChanged",
                         GLib.Variant("(sa{sv}as)",
                                      ("net.hadess.SensorProxy",
                                       {"AccelerometerOrientation":
                                        GLib.Variant("s", o)}, [])))
        return True

    GLib.timeout_add(POLL_US // 1000, tick)
    print("sensorproxy ready on %s" % BUS_NAME, flush=True)
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
