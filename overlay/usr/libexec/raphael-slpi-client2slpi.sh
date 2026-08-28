#!/bin/bash
# Android Client2Slpi equivalent — periodic RGB+parsed_lux (OEM type-10 only).
# Backlight2Slpi (BL+DC) stays in raphael-slpi-bl-notify on sysfs change.
set -euo pipefail
export PYTHONUNBUFFERED=1
export RAPHAEL_COLOR_LUX="${RAPHAEL_COLOR_LUX:-1}"
export RAPHAEL_PROX_RGB_MODE="${RAPHAEL_PROX_RGB_MODE:-hwc}"
NOTIFY=/usr/libexec/raphael-slpi-bl-notify.py
INTERVAL="${RAPHAEL_CLIENT2SLPI_INTERVAL:-1.0}"
BL=/sys/class/backlight/ae94000.dsi.0/brightness; [ -r "$BL" ] || BL=/sys/class/backlight/panel0-backlight/brightness

echo "client2slpi: COLOR-only every ${INTERVAL}s" >&2
while true; do
	b=0
	[ -r "$BL" ] && b=$(cat "$BL" 2>/dev/null || echo 0)
	"$NOTIFY" "$b" --als-only --rgb-only 2>/dev/null || true
	sleep "$INTERVAL"
done
