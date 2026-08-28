#!/bin/sh
# Raphael: map physical SIM slot and bind USIM provisioning session before MM.
set -eu

QRTR_DEV=qrtr://0
PHYSICAL_SLOT=2
MAX_WAIT=120

wait_modem() {
	for rp in /sys/class/remoteproc/remoteproc*; do
		[ -f "$rp/name" ] || continue
		if [ "$(cat "$rp/name")" = modem ]; then
			i=0
			while [ "$i" -lt "$MAX_WAIT" ]; do
				state=$(cat "$rp/state" 2>/dev/null || echo unknown)
				case "$state" in
				running)
					echo "raphael-sim-init: modem running after ${i}s"
					return 0
					;;
				crashed)
					echo "raphael-sim-init: modem state=crashed" >&2
					return 1
					;;
				esac
				i=$((i + 1))
				sleep 1
			done
			echo "raphael-sim-init: modem not running after ${MAX_WAIT}s (last state=$state)" >&2
			return 1
		fi
	done
	echo "raphael-sim-init: modem remoteproc not found" >&2
	return 1
}

wait_qmi() {
	i=0
	while [ "$i" -lt "$MAX_WAIT" ]; do
		if qmicli -p -d "$QRTR_DEV" --dms-get-ids >/dev/null 2>&1; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

if ! wait_modem; then
	exit 1
fi

if ! wait_qmi; then
	echo "raphael-sim-init: QMI not ready" >&2
	exit 1
fi

# Raphael single tray is wired to physical slot 2.
qmicli -p -d "$QRTR_DEV" --uim-switch-slot="$PHYSICAL_SLOT" || true
sleep 1

LOGICAL_SLOT=$(qmicli -p -d "$QRTR_DEV" --uim-get-slot-status 2>/dev/null | awk -v ps="$PHYSICAL_SLOT" '
	$0 ~ "Physical slot " ps ":" { active=1 }
	active && /Logical slot:/ { print $3; exit }
')
[ -z "$LOGICAL_SLOT" ] && LOGICAL_SLOT=1

QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)

i=0
while ! printf '%s' "$QMI_CARDS" | grep -Fq "Card state: 'present'"; do
	[ "$i" -ge 3 ] && break
	sleep 1
	i=$((i + 1))
	QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)
done

if ! printf '%s' "$QMI_CARDS" | grep -Fq "Card state: 'present'"; then
	echo "raphael-sim-init: no SIM present (after ${i}s), skip provisioning" >&2
	exit 0
fi

if ! printf '%s' "$QMI_CARDS" | grep -Fq "Primary GW:   session doesn't exist"; then
	qmicli -p -d "$QRTR_DEV" \
		--uim-change-provisioning-session='activate=no,session-type=primary-gw-provisioning' \
		|| true
	QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)
fi

AID=$(printf '%s' "$QMI_CARDS" | grep "usim (2)" -m1 -A3 \
	| grep -oE 'A0:[0-9A-F:]+' | head -1 | tr -d ':')
[ -z "$AID" ] && AID=A0000000871002FF86FFFF89FFFFFFFF

echo "raphael-sim-init: physical=$PHYSICAL_SLOT logical=$LOGICAL_SLOT aid=$AID"

qmicli -p -d "$QRTR_DEV" --uim-sim-power-on="$LOGICAL_SLOT" || true
qmicli -p -d "$QRTR_DEV" \
	--uim-change-provisioning-session="slot=${LOGICAL_SLOT},activate=yes,session-type=primary-gw-provisioning,aid=${AID}"

# MM may have started with sim-missing if provisioning was late; refresh once.
systemctl try-restart ModemManager.service --no-block 2>/dev/null || true

exit 0
