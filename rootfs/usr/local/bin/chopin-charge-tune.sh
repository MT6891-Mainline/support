#!/bin/sh
# chopin: the MT6360 charger comes up with the SDP default (500 mA input,
# 500 mA charge), which leaves ~85 mA for the battery once the phone's own load
# is subtracted - that is 1.7% per hour.  Raise both limits, but keep the input
# limit matched to what the port can actually deliver.
CHG=/sys/class/power_supply/mt6360-chg.2.auto

[ -d "$CHG" ] || exit 0

# "usb_type" prints every supported type with the active one in brackets,
# e.g. "Unknown [SDP] DCP CDP" - parse the bracketed token, not the whole line.
type=$(sed -n 's/.*\[\([A-Za-z0-9_-]*\)\].*/\1/p' $CHG/usb_type 2>/dev/null)
# A PD contract shows up as a high VBUS and "usb_power_delivery" in the typec
# port state; BC1.2 (usb_type) reports "Unknown" in that case, so check both.
pd=no
[ -r /sys/class/typec/port0/power_operation_mode ] &&
	grep -q usb_power_delivery /sys/class/typec/port0/power_operation_mode 2>/dev/null && pd=yes

case "$type" in
DCP|CDP|Type-C)	ilim=2000000; icc=3000000 ;;
*)		ilim=900000;  icc=1500000 ;;
esac

if [ "$pd" = yes ]; then
	# 9 V/12 V contract: the switcher can pass ~24 W, ~0.75C into the cell.
	ilim=2000000
	icc=4000000
fi

# Overrides (microamps): /etc/chopin-charge-limit sets the input limit,
# /etc/chopin-charge-current the battery side.  Lower the latter if the phone
# gets too warm while charging - 2500000 keeps the cell around 36 C instead of
# the 42 C it reaches at 4 A, at the cost of a longer charge.
[ -r /etc/chopin-charge-limit ] && ilim=$(cat /etc/chopin-charge-limit)
[ -r /etc/chopin-charge-current ] && icc=$(cat /etc/chopin-charge-current)

echo "$ilim" > $CHG/input_current_limit 2>/dev/null
# Battery side: 0.3C on a weak port, up to 0.6C on a dedicated charger.
echo "$icc" > $CHG/constant_charge_current 2>/dev/null
logger -t chopin-charge "usb_type='$type' pd=$pd input=${ilim}uA charge=${icc}uA"
