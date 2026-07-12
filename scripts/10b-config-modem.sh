#!/bin/bash
set -e

# 固化基带（modem）运行态修复：
#
#   1) raphael-sim-init(.sh+.service) —— 把物理 SIM 卡槽映射到逻辑槽并在 MM 之前
#      绑定 USIM 供应会话，解决"无 SIM"。enable。
#   2) raphael-no-mobile-data(.sh+.service) —— 开机关闭 GSM autoconnect，避免开机
#      误拨移动数据。enable。
#   3) ModemManager.service.d/raphael.conf —— MM 在 sim-init 之后启动。
#   4) 99-raphael-modem-norecover.rules —— 禁用 modem remoteproc 就地恢复，modem
#      崩溃时保持 "crashed" 而不拖垮整机（B 类安全网）。
#
# 注：不再安装 raphael-modem-offline（00161 固件 + IPA 补丁已解决 RF/数据面崩溃，
#     该服务会把 RF 永久锁 offline 导致无法注册）。
#     内核 IPA 修复在 patchs/raphael.patch；00161 固件在 firmware-xiaomi-raphael.deb。
#     移动数据需 qrtr8+ ModemManager（QMAPv4 patch，见 基带测试/mm/mm 编译产物）。
#   5) NetworkManager DNS —— dns=none，NM 不接管 /etc/resolv.conf；resolv.conf
#      由 04 写死公共 DNS（223.5.5.5/114.114.114.114），不跟随运营商下发。
#   6) raphael-cmcc-diff-mcfg —— SIM init 后、MM 前切 ROW MCFG（移动卡）。
#   7) raphael-wifi-recover —— modem soft-restart 后 ath10k 常 HTT 超时，自动 rebind。

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b] 📡 配置基带 modem 服务 + 崩溃隔离"

install -d rootdir/usr/local/sbin
install -d rootdir/etc/systemd/system/ModemManager.service.d
install -d rootdir/etc/udev/rules.d

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-sim-init.sh"
cat > rootdir/usr/local/sbin/raphael-sim-init.sh << 'EOF'
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
	[ "$i" -ge 15 ] && break
	sleep 1
	i=$((i + 1))
	QMI_CARDS=$(qmicli -p -d "$QRTR_DEV" --uim-get-card-status)
done

if ! printf '%s' "$QMI_CARDS" | grep -Fq "Card state: 'present'"; then
	echo "raphael-sim-init: no SIM present" >&2
	exit 1
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
EOF
chmod 755 rootdir/usr/local/sbin/raphael-sim-init.sh

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-no-mobile-data.sh"
cat > rootdir/usr/local/sbin/raphael-no-mobile-data.sh << 'EOF'
#!/bin/sh
# Keep cellular data disconnected at boot (user must manually connect).
set -eu

sleep 2

for u in $(nmcli -t -f UUID,TYPE connection show | awk -F: '$2=="gsm"{print $1}'); do
	nmcli connection modify "$u" connection.autoconnect no 2>/dev/null || true
done

nmcli device disconnect qrtr0 2>/dev/null || true

echo "raphael-no-mobile-data: gsm autoconnect disabled, qrtr0 disconnected"
EOF
chmod 755 rootdir/usr/local/sbin/raphael-no-mobile-data.sh

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-cmcc-diff-mcfg.sh (CMCC soft-restart)"
cat > rootdir/usr/local/sbin/raphael-cmcc-diff-mcfg.sh << 'EOF'
#!/bin/sh
# Before ModemManager: deactivate VoLTE CMCC, activate ROW, verified modem stop/start.
# Diff: CMCC commercial MCFG is Volte_OpenMkt only; CT/CU openmkt stay stable.
set -eu
QRTR=qrtr://0
LOG=/var/log/raphael-cmcc-diff-mcfg.log
CMCC_ID_FALLBACK='3A:89:6F:35:5D:EA:B6:10:3B:A9:E0:E8:3C:9E:17:DE:1B:C7:E5:08'
ROW_ID_FALLBACK='1E:6B:3C:74:D4:91:9D:E5:CA:30:F4:39:F0:A3:48:71:54:3C:2F:FA'

exec >>"$LOG" 2>&1
echo "==== $(date -Is) start ===="

wait_qmi() {
	i=0
	while [ "$i" -lt 45 ]; do
		if qmicli -p -d "$QRTR" --dms-get-ids >/dev/null 2>&1; then
			echo "qmi ready after ${i}s"
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	echo "qmi not ready"
	return 1
}

modem_rp() {
	for rp in /sys/class/remoteproc/remoteproc*; do
		[ "$(cat "$rp/name" 2>/dev/null)" = modem ] || continue
		echo "$rp"
		return 0
	done
	return 1
}

wait_modem_not_running() {
	rp=$1
	i=0
	while [ "$i" -lt 30 ]; do
		st=$(cat "$rp/state" 2>/dev/null || echo unknown)
		echo "modem state=$st (waiting not-running) t=${i}s"
		case "$st" in
		running) ;;
		*) return 0 ;;
		esac
		i=$((i + 1))
		sleep 1
	done
	return 1
}

wait_modem_running() {
	rp=$1
	i=0
	while [ "$i" -lt 90 ]; do
		st=$(cat "$rp/state" 2>/dev/null || echo unknown)
		echo "modem state=$st (waiting running) t=${i}s"
		[ "$st" = running ] && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

# One ID only (first match). qmicli type,id parsing breaks on newlines.
parse_id_for_desc() {
	needle=$1
	awk -v n="$needle" '
		/Description:/ {
			if (id != "" && desc ~ n) { print id; exit }
			desc=$0; id=""
			next
		}
		/^[\t ]*ID:/ {
			id=$0
			sub(/^[\t ]*ID:[\t ]*/, "", id)
			gsub(/[[:space:]]/, "", id)
			next
		}
		END {
			if (id != "" && desc ~ n) print id
		}
	' | head -n1
}

wait_qmi || exit 0

LIST=$(qmicli -p -d "$QRTR" --pdc-list-configs=software 2>/dev/null || true)
printf '%s\n' "$LIST" | awk '
	/Description:/ { d=$0 }
	/Status:/ { s=$0; if (s ~ /Active|Pending/) print d ORS s }
'

ACTIVE_DESC=$(printf '%s\n' "$LIST" | awk '
	/Description:/ { d=$0 }
	/Status:/ {
		if ($0 ~ /Active/) {
			print d
			exit
		}
	}
')
case "$ACTIVE_DESC" in
*ROW_Commercial*)
	echo "ROW already Active → skip MCFG switch/modem restart (protect WiFi)"
	echo "==== $(date -Is) done ===="
	exit 0
	;;
esac

CMCC_ID=$(printf '%s\n' "$LIST" | parse_id_for_desc "Volte_OpenMkt-Commercial-CMCC")
ROW_ID=$(printf '%s\n' "$LIST" | parse_id_for_desc "ROW_Commercial")
[ -n "${CMCC_ID:-}" ] || CMCC_ID=$CMCC_ID_FALLBACK
[ -n "${ROW_ID:-}" ] || ROW_ID=$ROW_ID_FALLBACK
# strip any accidental whitespace/newlines
CMCC_ID=$(printf '%s' "$CMCC_ID" | tr -d '\r\n[:space:]')
ROW_ID=$(printf '%s' "$ROW_ID" | tr -d '\r\n[:space:]')
echo "CMCC_ID=$CMCC_ID"
echo "ROW_ID=$ROW_ID"

echo "deactivate CMCC VoLTE"
if qmicli -p -d "$QRTR" --pdc-deactivate-config="software,$CMCC_ID"; then
	echo "deactivate ok"
else
	echo "deactivate failed"
fi

echo "activate ROW"
if qmicli -p -d "$QRTR" --pdc-activate-config="software,$ROW_ID"; then
	echo "activate ok"
else
	echo "activate failed"
fi

echo "--- after switch ---"
qmicli -p -d "$QRTR" --pdc-list-configs=software 2>/dev/null | awk '
	/Description:/ { d=$0 }
	/Status:/ { s=$0; if (s ~ /Active|Pending/) print d ORS s }
' || true

rp=$(modem_rp) || exit 0
echo "verified stop/start $rp"
echo stop >"$rp/state" || echo "ERROR: cannot write stop"
wait_modem_not_running "$rp" || echo "ERROR: modem still running after stop"
sleep 1
echo start >"$rp/state" || echo "ERROR: cannot write start"
wait_modem_running "$rp" || echo "ERROR: modem not running after start"
wait_qmi || echo "qmi not ready after restart"

echo "--- final ---"
qmicli -p -d "$QRTR" --pdc-list-configs=software 2>/dev/null | awk '
	/Description:/ { d=$0 }
	/Status:/ { s=$0; if (s ~ /Active|Pending/) print d ORS s }
' || true
echo "==== $(date -Is) done ===="
EOF
chmod 755 rootdir/usr/local/sbin/raphael-cmcc-diff-mcfg.sh

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ raphael-wifi-recover.sh (ath10k after modem MCFG restart)"
cat > rootdir/usr/local/sbin/raphael-wifi-recover.sh << 'EOF'
#!/bin/sh
# After CMCC MCFG modem soft-restart, ath10k often fails HTT (-110) mid-probe.
# Wait briefly for wlan0; if missing, rebind ath10k_snoc.
set -eu
LOG=/var/log/raphael-wifi-recover.log
exec >>"$LOG" 2>&1
echo "==== $(date -Is) start ===="

WIFI_DEV=18800000.wifi
DRV=/sys/bus/platform/drivers/ath10k_snoc

if [ -e /sys/class/net/wlan0 ]; then
	echo "wlan0 already present"
	echo "==== $(date -Is) done ===="
	exit 0
fi

i=0
while [ "$i" -lt 35 ]; do
	if [ -e /sys/class/net/wlan0 ]; then
		echo "wlan0 appeared after ${i}s"
		echo "==== $(date -Is) done ===="
		exit 0
	fi
	i=$((i + 1))
	sleep 1
done

echo "wlan0 missing after ${i}s → rebind $WIFI_DEV"
if [ ! -d "$DRV" ]; then
	echo "ERROR: $DRV missing"
	exit 1
fi
echo "$WIFI_DEV" >"$DRV/unbind" 2>/dev/null || true
sleep 1
echo "$WIFI_DEV" >"$DRV/bind" 2>/dev/null || true

i=0
while [ "$i" -lt 25 ]; do
	if [ -e /sys/class/net/wlan0 ]; then
		echo "wlan0 recovered after rebind ${i}s"
		echo "==== $(date -Is) done ===="
		exit 0
	fi
	i=$((i + 1))
	sleep 1
done

echo "ERROR: wlan0 still missing after rebind"
echo "==== $(date -Is) done ===="
exit 1
EOF
chmod 755 rootdir/usr/local/sbin/raphael-wifi-recover.sh

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ systemd units"
cat > rootdir/etc/systemd/system/raphael-sim-init.service << 'EOF'
[Unit]
Description=Raphael SIM slot 1 power-on via QMI
After=remoteproc.target sys-subsystem-net-devices-rmnet_ipa0.device
Before=ModemManager.service
Wants=remoteproc.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=300
StartLimitBurst=24
ExecStart=/usr/local/sbin/raphael-sim-init.sh

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/raphael-no-mobile-data.service << 'EOF'
[Unit]
Description=Raphael disable GSM autoconnect at boot
After=NetworkManager.service ModemManager.service
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-no-mobile-data.sh

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/raphael-cmcc-diff-mcfg.service << 'EOF'
[Unit]
Description=Raphael CMCC modem soft-restart before ModemManager
DefaultDependencies=no
After=raphael-sim-init.service
Before=ModemManager.service
Wants=raphael-sim-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-cmcc-diff-mcfg.sh
TimeoutStartSec=180
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/raphael-wifi-recover.service << 'EOF'
[Unit]
Description=Raphael recover WiFi after modem MCFG soft-restart
DefaultDependencies=no
After=raphael-cmcc-diff-mcfg.service
Wants=raphael-cmcc-diff-mcfg.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-wifi-recover.sh
TimeoutStartSec=90
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat > rootdir/etc/systemd/system/ModemManager.service.d/raphael.conf << 'EOF'
[Unit]
After=raphael-sim-init.service raphael-cmcc-diff-mcfg.service
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ udev modem norecover 规则"
cat > rootdir/etc/udev/rules.d/99-raphael-modem-norecover.rules << 'EOF'
# Raphael: modem(mpss) SSR recovery via TZ pas_shutdown hangs in EL3 when
# RF firmware asserts, wedging the CPU and hard-locking the whole system.
# Disable in-place recovery so a modem crash stays contained (modem ends up
# in "crashed" state) instead of dragging down the machine. See
# RAPHAEL-MODEM-STATUS.md 3.1A. Remove once RF (A-fix) makes modem stable.
SUBSYSTEM=="remoteproc", ACTION=="add", ATTR{name}=="modem", ATTR{recovery}="disabled"
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ DNS: NM dns=none + 固定公共 DNS"
install -d rootdir/etc/NetworkManager/conf.d

# NM 不接管 resolv.conf，保留 04 写死的公共 DNS；否则连上链路后 NM 会用
# 运营商下发的 DNS 覆盖 resolv.conf，导致解析异常。
cat > rootdir/etc/NetworkManager/conf.d/raphael-dns.conf << 'EOF'
[main]
# Do not let NetworkManager manage /etc/resolv.conf.
# We pin public DNS in /etc/resolv.conf (see 04-config-network.sh) so that
# neither the GSM (operator) bearer nor WiFi can override it.
dns=none
rc-manager=unmanaged
EOF

# 重新断言静态 resolv.conf：06 安装 systemd-resolved/ubuntu-desktop 时其 postinst
# 可能把 /etc/resolv.conf 软链到 stub，这里覆盖回固定公共 DNS（10b 晚于 06）。
rm -f rootdir/etc/resolv.conf
cat > rootdir/etc/resolv.conf << 'EOF'
# 公共 DNS（固定，不随链路变化）。与 04-config-network.sh 保持一致。
nameserver 223.5.5.5
nameserver 114.114.114.114
EOF

# systemd-resolved 仅在被软链到 stub 时才接管 resolv.conf；这里是静态文件，
# 它不会改写。禁用其 stub 监听以免与静态配置混淆。
install -d rootdir/etc/systemd/resolved.conf.d
cat > rootdir/etc/systemd/resolved.conf.d/raphael.conf << 'EOF'
[Resolve]
DNS=223.5.5.5 114.114.114.114
FallbackDNS=
DNSStubListener=no
EOF

# ---------------------------------------------------------------------------
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b]   └─ 启用服务"
chroot rootdir systemctl enable raphael-sim-init.service
chroot rootdir systemctl enable raphael-no-mobile-data.service
chroot rootdir systemctl enable raphael-cmcc-diff-mcfg.service
chroot rootdir systemctl enable raphael-wifi-recover.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10b] ✅ 基带配置完成"
