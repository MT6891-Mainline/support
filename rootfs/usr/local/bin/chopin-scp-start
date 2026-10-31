#!/bin/sh
# Bring the SCP core up and nudge the sensor bring-up.
#
# The SCP is not started by the kernel: scp-chopin exposes the sequence through
# debugfs and leaves it to userspace.  On the Alpine image /etc/local.d/
# 10-chsensor.start did this; Debian needs an equivalent or the core stays
# "SCP A is not ready" and every in_accel_*_raw read returns -EAGAIN.
#
#   patchscp 2   group 0 (base) + group 1 (power gate) of the firmware patches
#   fullreset    hold both cores in reset
#   sram         reload TCM
#   start        release core0 and print the boot PC
#   retry        0.4 s later: re-run the chsensor bring-up inside the firmware's
#                own listening window (it gives up on its own at ~0.9 s)
set -u
D=/sys/kernel/debug

mount -t debugfs none $D 2>/dev/null

[ -e $D/scp-chopin/patchscp ] || { echo "no scp-chopin debugfs"; exit 1; }

echo 2 > $D/scp-chopin/patchscp
echo 1 > $D/scp-chopin/fullreset
echo 1 > $D/scp-chopin/sram
sleep 1
echo 1 > $D/scp-chopin/start
sleep 0.4
[ -e $D/chsensor/retry ] && echo 1 > $D/chsensor/retry

cat /sys/class/misc/scp/scp_A_status 2>/dev/null
