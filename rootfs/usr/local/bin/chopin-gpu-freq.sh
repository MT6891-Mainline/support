#!/bin/sh
# Optionally set the GPU core clock at boot.
#
# The kernel exposes /sys/devices/platform/13000000.mali/core_clk_rate, which
# retunes mfgpll the safe way (park the mfg_sel mux on clk26m, retune the PLL
# with no consumer, switch back).  Doing it at boot is only safe *before* the
# compositor starts, otherwise an in-flight GPU job would see the mux drop.
#
# The value is read from /etc/chopin-gpu-freq (a plain number in Hz).  With no
# file this script does nothing, so the board keeps the bootloader rate.
#
# Measured with glmark2-es2-wayland 800x600 on this board:
#   350 MHz -> 1919   (boot rate, no config)
#   450 MHz -> 1994
#   650 MHz -> 2139   <- best, and stable in a full-suite stress run
#   750 MHz -> 2060   <- *slower* than 650, a sign of marginal timing
#
# NOTE: the GPU is powered from MT6315 7_vbuck1, which Linux cannot reach (SPMI
# is not bound), so the voltage stays at whatever the bootloader set for 350 MHz.
# Running above the boot rate is therefore an undervolt: fine in testing, not
# something to rely on for sustained load.
set -u

KNOB=/sys/devices/platform/13000000.mali/core_clk_rate
CONF=/etc/chopin-gpu-freq

[ -f "$CONF" ] || exit 0
[ -w "$KNOB" ] || { echo "chopin-gpu-freq: no $KNOB"; exit 0; }

hz=$(tr -dc '0-9' < "$CONF")
[ -n "$hz" ] || { echo "chopin-gpu-freq: empty $CONF"; exit 0; }

echo "$hz" > "$KNOB" || { echo "chopin-gpu-freq: write failed"; exit 0; }
echo "chopin-gpu-freq: GPU core clock now $(cat "$KNOB") Hz"
