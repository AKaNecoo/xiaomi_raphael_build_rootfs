#!/bin/bash
# Post-hexagon ALS init: TCS3701 RVED2 path (gate → fopen-2 → RGB → BL+DC → gate).
# systemd: ExecStartPost=+ (root). Manual: may run as fastrpc if backlight is group-readable.
set -euo pipefail
if [ "$(id -u)" -ne 0 ] && { [ ! -r /sys/class/backlight/ae94000.dsi.0/brightness ] && [ ! -r /sys/class/backlight/panel0-backlight/brightness ]; }; then
	echo "raphael-als-oem-init: need root or fastrpc backlight access" >&2
	exit 1
fi

export RAPHAEL_COLOR_LUX=1
export RAPHAEL_BL_FIELD9=dbv
export RAPHAEL_ALS_FOPEN_SYNC=1
export RAPHAEL_OEM_ORDER=android
export RAPHAEL_PROX_RGB_MODE="${RAPHAEL_PROX_RGB_MODE:-hwc}"
export RAPHAEL_GATE_RETRIES="${RAPHAEL_GATE_RETRIES:-3}"
export RAPHAEL_TCS_PATH_SETTLE="${RAPHAEL_TCS_PATH_SETTLE:-0.5}"
BL="${1:-$(cat /sys/class/backlight/ae94000.dsi.0/brightness 2>/dev/null || cat /sys/class/backlight/panel0-backlight/brightness 2>/dev/null || echo 700)}"

# Warm SLPI ALS instance before gate/OEM (sub_B2086CA4 must be active).
timeout 3 ssccli --sensor light --timeout 2 >/dev/null 2>&1 || true

(
	timeout 25 ssccli --sensor light --timeout 22 >/dev/null 2>&1
) &
_STREAM=$!
sleep 2

/usr/libexec/raphael-slpi-bl-notify.py "$BL" --als-only --tcs-path-init 2>/dev/null || \
	/usr/libexec/raphael-slpi-bl-notify.py "$BL" --als-only --tcs-path-init
sleep 2
kill "$_STREAM" 2>/dev/null || true
wait "$_STREAM" 2>/dev/null || true
exit 0
