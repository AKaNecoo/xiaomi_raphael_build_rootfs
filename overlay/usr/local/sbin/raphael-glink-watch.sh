#!/bin/bash
# raphael-glink-watch.sh — glink wedge watchdog (sm8150 raphael)
#
# Watches the kernel log for repeated glink/remoteproc wedge signatures and,
# once a remote is clearly wedged, triggers crash-recovery on it via debugfs.
# Works in combination with the kernel fixes (bounded SCM/fastrpc waits +
# remote heap ownership reclaim): after the recovery restart the DSP comes
# back cleanly instead of hanging in "stalled initialization".
#
# Install: /usr/local/sbin/raphael-glink-watch.sh
# Unit:    raphael-glink-watch.service (Type=simple, Restart=on-failure)
#
# Requires: debugfs mounted, root (runs as system service)

set -u

# How many consecutive wedge events before we act (one glink intent timeout
# fires roughly every 10s, so 6 events ≈ 60s of continuous wedging).
THRESHOLD="${RAPHAEL_GLINK_WATCH_THRESHOLD:-6}"

# Maps the remoteproc DT address (first field of the log line) to the
# /sys/class/remoteproc index. The modem (4080000) is deliberately excluded:
# its recovery is disabled and it is the SSR master.
declare -A ADDR_TO_RPROC=(
    [2400000]=0   # slpi
    [8300000]=2   # cdsp
    [17300000]=3  # adsp
)

# Messages that indicate a wedged link/handshake.
#  - "intent request timed out": glink data link wedged (remote no longer
#    answers intent requests).
#  - "timeout waiting for subsystem event response": q6v5_pas handshake
#    timeout (usually during boot when the remote firmware stalls).
PATTERNS=(
    'intent request timed out'
    'timeout waiting for subsystem event response'
)

declare -A COUNT

recover_remote() {
    local idx="$1"
    local name
    local recovery

    name=$(cat "/sys/class/remoteproc/remoteproc${idx}/name" 2>/dev/null) || return 0
    recovery=$(cat "/sys/kernel/debug/remoteproc/remoteproc${idx}/recovery" 2>/dev/null) || return 0

    # Never touch remotes whose in-kernel recovery is disabled (modem).
    [ "$recovery" = "enabled" ] || return 0

    logger -t raphael-glink-watch "wedge detected on ${name}, triggering crash recovery"
    echo 1 > "/sys/kernel/debug/remoteproc/remoteproc${idx}/crash" 2>/dev/null || true
}

journalctl -k -f -n 0 --no-pager 2>/dev/null | while read -r line; do
    matched=0
    for pat in "${PATTERNS[@]}"; do
        case "$line" in
            *"$pat"*) matched=1 ;;
        esac
    done
    [ "$matched" -eq 1 ] || continue

    # Extract the remoteproc address, e.g. "17300000.remoteproc:glink-edge:"
    addr=$(printf '%s\n' "$line" | sed -n 's/.*\b\([0-9a-f]*\)\.remoteproc:.*/\1/p')
    [ -n "$addr" ] || continue

    idx="${ADDR_TO_RPROC[$addr]:-}"
    [ -n "$idx" ] || continue

    COUNT[$idx]=$(( ${COUNT[$idx]:-0} + 1 ))
    if [ "${COUNT[$idx]}" -ge "$THRESHOLD" ]; then
        recover_remote "$idx"
        COUNT[$idx]=0
    fi
done
