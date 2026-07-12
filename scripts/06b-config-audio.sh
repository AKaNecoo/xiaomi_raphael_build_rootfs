#!/bin/bash
set -e

# ================================================================
# [06b] Raphael 音频（配合 alsa-xiaomi-raphael UCM2）
# ----------------------------------------------------------------
# 硬件通路由 UCM2 负责。PipeWire 相对 PulseAudio 的两个软件问题：
# 1) 默认采样格式 S24_32LE → 扬声器/耳机几乎无声；强制 S16LE 后 100% 正常
# 2) WirePlumber 默认音量 0.4^3≈6%；覆盖为 1.0，不超 100%
#
# 双路径（按发行版默认音频栈）：
# A) jammy / bookworm 等有 pulseaudio → PulseAudio（软件音量正常）
#    只 mask PipeWire 用户服务，绝不 purge（避免拆桌面）
# B) noble / trixie / resolute 等默认 PipeWire → soft-mixer + S16LE
#    jammy/bookworm 的 GNOME 仍是 PulseAudio，切勿全局强制 PipeWire。
#    例外：Ubuntu noble+ / Debian trixie+ 的 GNOME（Remote Login）——
#    仓库里仍可能 apt-cache show 到 pulseaudio，但若装上并 mask PipeWire，
#    RDP 会报 Couldn't connect pipewire context；仅对该组合强制走路径 B。
# ================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
. "$CONFIG_DIR/build-config.sh"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b] 🔊 配置音频服务 (Raphael)"

_use_pulseaudio=false
if chroot rootdir apt-cache show pulseaudio >/dev/null 2>&1; then
	_use_pulseaudio=true
fi

# 新版 GNOME：仓库仍可能有 pulseaudio 包，但桌面/Remote Login 依赖 PipeWire
_force_pw_gnome=false
case "${UBUNTU_VERSION:-}" in
	noble|oracular|plucky|questing|resolute) _force_pw_gnome=true ;;
esac
case "${DEBIAN_VERSION:-}" in
	trixie|forky|sid) _force_pw_gnome=true ;;
esac
if [ "$_force_pw_gnome" = true ] && [ "$DESKTOP_ENV" = "gnome" ]; then
	_use_pulseaudio=false
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b]   └─ ${UBUNTU_VERSION:-${DEBIAN_VERSION}} GNOME：强制 PipeWire（Remote Login）"
fi

if [ "$_use_pulseaudio" = true ]; then
	# ── 路径 A：PulseAudio（jammy / bookworm 等）────────────────────────
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b]   └─ 使用 PulseAudio（本发行版可用）"
	chroot rootdir apt-get install -y pulseaudio pulseaudio-utils

	for unit in pipewire.socket pipewire-pulse.socket pipewire.service \
	            pipewire-pulse.service wireplumber.service \
	            pipewire-media-session.service; do
		chroot rootdir systemctl --global mask "$unit" 2>/dev/null || true
	done
	chroot rootdir systemctl --global unmask pulseaudio.service pulseaudio.socket 2>/dev/null || true
	chroot rootdir systemctl --global enable pulseaudio.service pulseaudio.socket 2>/dev/null || true

else
	# ── 路径 B：PipeWire（noble / trixie / resolute 等）──────────────────
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b]   └─ 使用 PipeWire + soft-mixer + S16LE"

	# 若误装了 pulseaudio，卸掉对 PipeWire 的抢占（保留库即可）
	chroot rootdir systemctl --global unmask pipewire.service pipewire.socket \
		pipewire-pulse.service pipewire-pulse.socket wireplumber.service \
		pipewire-media-session.service 2>/dev/null || true
	chroot rootdir systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
	chroot rootdir apt-get remove -y pulseaudio 2>/dev/null || true

	PW_CANDIDATES="pipewire pipewire-pulse pipewire-audio pipewire-alsa \
	    pipewire-audio-client-libraries libspa-0.2-bluetooth wireplumber \
	    pulseaudio-utils"
	PW_INSTALL=""
	for p in $PW_CANDIDATES; do
		if chroot rootdir apt-cache show "$p" >/dev/null 2>&1; then
			PW_INSTALL="$PW_INSTALL $p"
		fi
	done
	if [ -n "$PW_INSTALL" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b]   └─ 确保 PipeWire 包:$PW_INSTALL"
		chroot rootdir apt-get install -y $PW_INSTALL
	fi

	# WirePlumber 0.4：在官方 50-alsa-config.lua 上启用 soft-mixer + UCM + S16LE。
	# 不要另写 table.insert 规则文件——会触发 alsa.lua "table index is nil"，
	# ACP 只剩 off/pro-audio，丢掉 UCM HiFi（Speaker/Headphone）链路。
	install -d rootdir/etc/wireplumber/main.lua.d
	if [ -f rootdir/usr/share/wireplumber/main.lua.d/40-device-defaults.lua ]; then
		sed 's/--\["default-volume"\] = 0.064,/["default-volume"] = 1.0,/' \
			rootdir/usr/share/wireplumber/main.lua.d/40-device-defaults.lua \
			> rootdir/etc/wireplumber/main.lua.d/40-device-defaults.lua
	fi
	if [ -f rootdir/usr/share/wireplumber/main.lua.d/50-alsa-config.lua ]; then
		cp rootdir/usr/share/wireplumber/main.lua.d/50-alsa-config.lua \
			rootdir/etc/wireplumber/main.lua.d/50-alsa-config.lua
		# 启用 UCM（保留 HiFi Speaker/Headphone）+ 软件音量（TFA9874 无硬件音量）
		sed -i 's/--\["api.alsa.use-ucm"\] = true,/\["api.alsa.use-ucm"\] = true,/' \
			rootdir/etc/wireplumber/main.lua.d/50-alsa-config.lua
		sed -i 's/--\["api.alsa.soft-mixer"\] = false,/\["api.alsa.soft-mixer"\] = true,/' \
			rootdir/etc/wireplumber/main.lua.d/50-alsa-config.lua
		# S16LE：默认 S24_32LE 在 Speaker/Headphone 上几乎无声
		sed -i '/matches = {/{
			:a; n
			/--\["node.nick"\]/ {
				i\      ["api.alsa.soft-mixer"] = true,
				i\      ["audio.format"] = "S16LE",
				i\      ["audio.rate"] = 48000,
			}
		}' rootdir/etc/wireplumber/main.lua.d/50-alsa-config.lua 2>/dev/null || true
		# 上面复杂 sed 可能因发行版缩进失败；用 Python 可靠注入一次
		python3 - <<'PY' || true
from pathlib import Path
p = Path("rootdir/etc/wireplumber/main.lua.d/50-alsa-config.lua")
t = p.read_text()
if '["audio.format"] = "S16LE"' in t:
    raise SystemExit(0)
needle = '''    apply_properties = {
      --["node.nick"]              = "My Node",
      --["node.description"]       = "My Node Description",
      --["priority.driver"]        = 100,'''
repl = '''    apply_properties = {
      -- Raphael: soft-mixer + S16LE (keep UCM HiFi path)
      ["api.alsa.soft-mixer"] = true,
      ["audio.format"] = "S16LE",
      ["audio.rate"] = 48000,
      --["node.nick"]              = "My Node",
      --["node.description"]       = "My Node Description",
      --["priority.driver"]        = 100,'''
if needle not in t:
    raise SystemExit("50-alsa-config.lua node block not found; skip S16LE inject")
p.write_text(t.replace(needle, repl, 1))
PY
	fi

	# WirePlumber 0.5+（resolute 等；0.4 忽略此目录）
	install -d rootdir/etc/wireplumber/wireplumber.conf.d
	cat > rootdir/etc/wireplumber/wireplumber.conf.d/50-raphael-audio.conf << 'EOF'
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.*" } ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        api.alsa.use-ucm = true
        api.alsa.use-acp = true
      }
    }
  }
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        audio.format = "S16LE"
        audio.rate = 48000
      }
    }
  }
]
EOF

	install -d rootdir/usr/local/sbin
	cat > rootdir/usr/local/sbin/raphael-audio-setup.sh << 'EOF'
#!/bin/bash
# Force UCM HiFi → Speaker (TFA9874). Never use pro-audio / auto_null.
# If ALSA card is gone (WCD/SlimBus ENOSPC after bad RDP audio), only reboot helps.
# Do NOT restart WirePlumber from here (deadlocks ExecStartPost / PartOf loops).
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

for _ in 1 2 3 4 5 6 7 8 9 10; do
	wpctl status >/dev/null 2>&1 && break
	sleep 0.5
done

alsa_card_present() {
	grep -qE '^\s*[0-9]+\s+\[' /proc/asound/cards 2>/dev/null
}

if ! alsa_card_present; then
	logger -t raphael-audio-setup "no ALSA card (/proc/asound/cards empty) → reboot required"
	exit 2
fi

amixer -c 0 sset 'QUAT_MI2S_RX Audio Mixer MultiMedia2' on >/dev/null 2>&1 || true
amixer -c 0 sset 'SLIMBUS_0_RX Audio Mixer MultiMedia1' on >/dev/null 2>&1 || true

ensure_hifi() {
	local cards
	cards=$(pactl list cards 2>/dev/null || true)
	echo "$cards" | grep -qE 'HiFi:|HiFi quality' || return 1
	pactl set-card-profile alsa_card.platform-sound HiFi >/dev/null 2>&1 || true
	sleep 0.3
	pactl list cards 2>/dev/null | grep -qE '活动配置：HiFi|Active Profile: HiFi'
}

# Wait for ACP/UCM HiFi; rdp-audio-watch will retry if still missing.
for _ in $(seq 1 20); do
	ensure_hifi && break
	sleep 0.5
done
if ! ensure_hifi; then
	if ! alsa_card_present; then
		logger -t raphael-audio-setup "ALSA card vanished → reboot required"
		exit 2
	fi
	logger -t raphael-audio-setup "HiFi missing after wait (no WP restart)"
	exit 1
fi

pick_sink() {
	wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' \
		| sed -n "s/.*[[:space:]]\([0-9]\+\)\.[[:space:]]*.*$1.*/\1/p" | head -1
}

ID=$(pick_sink 'Speaker')
[ -z "${ID:-}" ] && ID=$(pick_sink 'Headphone')
if [ -z "${ID:-}" ]; then
	logger -t raphael-audio-setup "no Speaker/Headphone sink after HiFi attempt"
	exit 1
fi

SNAME=$(pw-cli info "$ID" 2>/dev/null | sed -n 's/.*node.name = "\([^"]*\)".*/\1/p' | head -1)
case "${SNAME:-}" in
	*pro-output*|*auto_null*|*grd_remote*)
		logger -t raphael-audio-setup "refusing non-HiFi node $SNAME"
		exit 1
		;;
esac

NODES="${HOME}/.local/state/wireplumber/default-nodes"
mkdir -p "$(dirname "$NODES")"
cat > "$NODES" << NODEOF
[default-nodes]
default.configured.audio.sink=${SNAME}
default.configured.audio.sink.0=${SNAME}
NODEOF
pw-metadata -n default 0 default.configured.audio.sink "{\"name\":\"${SNAME}\"}" >/dev/null 2>&1 || true
pw-metadata -n default 0 default.audio.sink "{\"name\":\"${SNAME}\"}" >/dev/null 2>&1 || true
wpctl set-default "$ID" >/dev/null 2>&1 || true
pactl set-default-sink "$SNAME" >/dev/null 2>&1 || true
wpctl set-mute "$ID" 0 >/dev/null 2>&1 || true
wpctl set-volume "$ID" 1.0 >/dev/null 2>&1 || true

ROUTES="${HOME}/.local/state/wireplumber/default-routes"
if [ -f "$ROUTES" ] && grep -qE 'channelVolumes=0\.[0-9]' "$ROUTES" 2>/dev/null; then
	sed -i -E 's/channelVolumes=0\.[0-9.]+;0\.[0-9.]+;/channelVolumes=1.0;1.0;/' "$ROUTES" 2>/dev/null || true
fi
logger -t raphael-audio-setup "restored $SNAME id=$ID"
EOF
	chmod 755 rootdir/usr/local/sbin/raphael-audio-setup.sh

	# Restore HiFi after RDP disconnect. NEVER fight an active RDP session
	# (remote-audio → 虚拟输出 is expected; restarting WP then kills WCD/SlimBus).
	cat > rootdir/usr/local/sbin/raphael-rdp-audio-watch.sh << 'EOF'
#!/bin/bash
# After GNOME Remote Desktop disconnect, restore HiFi Speaker.
# While --handover is running, leave sinks alone (remote audio uses 虚拟输出).
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
RESTORE=/usr/local/sbin/raphael-audio-setup.sh
had_handover=0
cooldown=0

rdp_active() {
	pgrep -f 'gnome-remote-desktop-daemon --handover' >/dev/null 2>&1
}

alsa_card_present() {
	grep -qE '^\s*[0-9]+\s+\[' /proc/asound/cards 2>/dev/null
}

needs_restore() {
	local def desc cards
	def=$(pactl get-default-sink 2>/dev/null || true)
	case "${def:-}" in
		*auto_null*|*grd_remote*|*pro-output*|"") return 0 ;;
	esac
	desc=$(wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' \
		| sed -n 's/.*\*[[:space:]]*[0-9]\+\.[[:space:]]*\(.*\)/\1/p' | head -1)
	case "${desc:-}" in
		*虚拟*|*Pro\ *|*\ Pro|*Pro) return 0 ;;
	esac
	cards=$(pactl list cards 2>/dev/null || true)
	echo "$cards" | grep -qE '活动配置：HiFi|Active Profile: HiFi' || return 0
	echo "${desc:-}" | grep -qE 'Speaker|Headphone|TFA|WCD' && return 1
	return 0
}

while true; do
	if rdp_active; then
		had_handover=1
	elif [ "$had_handover" = 1 ]; then
		sleep 2
		logger -t raphael-rdp-audio "RDP handover ended → restore HiFi Speaker"
		rc=0
		"$RESTORE" 2>/dev/null || rc=$?
		had_handover=0
		# exit 2 = ALSA dead; stop thrashing until reboot
		if [ "$rc" = 2 ] || ! alsa_card_present; then
			logger -t raphael-rdp-audio "ALSA/WCD dead → reboot required (cooldown 5min)"
			cooldown=100
		else
			cooldown=5
		fi
	elif [ "$cooldown" -gt 0 ]; then
		cooldown=$((cooldown - 1))
	elif needs_restore && ! rdp_active; then
		logger -t raphael-rdp-audio "bad sink/profile → restore HiFi Speaker"
		rc=0
		"$RESTORE" 2>/dev/null || rc=$?
		if [ "$rc" = 2 ] || ! alsa_card_present; then
			logger -t raphael-rdp-audio "ALSA/WCD dead → reboot required (cooldown 5min)"
			cooldown=100
		else
			cooldown=10
		fi
	fi
	sleep 3
done
EOF
	chmod 755 rootdir/usr/local/sbin/raphael-rdp-audio-watch.sh

	# Headset jack → switch default sink + enable WCD headphone mixers
	cat > rootdir/usr/local/sbin/raphael-headset-switch.sh << 'EOF'
#!/bin/bash
# Switch PipeWire default sink on Headset Jack plug/unplug.
set -euo pipefail

jack_plugged() {
	amixer -c 0 cget numid=94 2>/dev/null | grep -q "values=on"
}

enable_headphone_path() {
	amixer -c 0 cset name='SLIM RX0 MUX' 'AIF1_PB' >/dev/null 2>&1 || true
	amixer -c 0 cset name='SLIM RX1 MUX' 'AIF1_PB' >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX INT1_1 MIX1 INP0' 'RX0' >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX INT2_1 MIX1 INP0' 'RX1' >/dev/null 2>&1 || true
	amixer -c 0 cset name='COMP1 Switch' on >/dev/null 2>&1 || true
	amixer -c 0 cset name='COMP2 Switch' on >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX INT1 DEM MUX' 'CLSH_DSM_OUT' >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX INT2 DEM MUX' 'CLSH_DSM_OUT' >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX1 Digital Volume' 68 >/dev/null 2>&1 || true
	amixer -c 0 cset name='RX2 Digital Volume' 68 >/dev/null 2>&1 || true
	amixer -c 0 sset 'SLIMBUS_0_RX Audio Mixer MultiMedia1' on >/dev/null 2>&1 || true
}

find_sink() {
	local kind=$1
	wpctl status 2>/dev/null | sed -n '/Sinks:/,/Sources:/p' \
		| sed -n "s/.*[[:space:]]\([0-9]\+\)\.[[:space:]]*.*${kind}.*/\1/p" \
		| head -1
}

apply_sink() {
	local kind=$1
	local id=""
	local _
	for _ in $(seq 1 15); do
		id=$(find_sink "$kind" || true)
		[ -n "$id" ] && break
		sleep 0.3
	done
	[ -z "$id" ] && return 1
	wpctl set-default "$id" 2>/dev/null || true
	wpctl set-mute "$id" 0 2>/dev/null || true
	wpctl set-volume "$id" 1.0 2>/dev/null || true
	logger -t raphael-headset "default -> $kind id=$id" || true
}

switch_now() {
	if jack_plugged; then
		enable_headphone_path
		apply_sink "Headphone"
		sp=$(find_sink "Speaker" || true)
		[ -n "${sp:-}" ] && wpctl set-mute "$sp" 1 2>/dev/null || true
	else
		sp=$(find_sink "Speaker" || true)
		[ -n "${sp:-}" ] && wpctl set-mute "$sp" 0 2>/dev/null || true
		apply_sink "Speaker"
	fi
}

for _ in $(seq 1 30); do
	wpctl status >/dev/null 2>&1 && break
	sleep 0.5
done
switch_now
prev=""
while true; do
	cur=$(jack_plugged && echo on || echo off)
	if [ "$cur" != "$prev" ]; then
		sleep 0.25
		switch_now
		prev=$cur
	fi
	sleep 0.5
done
EOF
	chmod 755 rootdir/usr/local/sbin/raphael-headset-switch.sh

	install -d rootdir/etc/systemd/user
	cat > rootdir/etc/systemd/user/raphael-audio-setup.service << 'EOF'
[Unit]
Description=Raphael audio setup (routes + 100% soft volume)
After=wireplumber.service pipewire.service pipewire-pulse.service
Wants=wireplumber.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-audio-setup.sh
RemainAfterExit=yes
TimeoutStartSec=30

[Install]
WantedBy=default.target
EOF

	cat > rootdir/etc/systemd/user/raphael-headset-switch.service << 'EOF'
[Unit]
Description=Raphael headset jack -> PipeWire sink switch
After=wireplumber.service pipewire.service
PartOf=wireplumber.service

[Service]
ExecStart=/usr/local/sbin/raphael-headset-switch.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

	cat > rootdir/etc/systemd/user/raphael-rdp-audio-watch.service << 'EOF'
[Unit]
Description=Raphael restore HiFi Speaker after RDP / virtual sink
After=pipewire.service wireplumber.service
Wants=wireplumber.service

[Service]
ExecStart=/usr/local/sbin/raphael-rdp-audio-watch.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
	# Noble 用户单元常从 /etc/xdg/systemd/user 加载；勿 PartOf=graphical-session
	# （会话抖动会把 watch 杀掉，断 RDP 后无法恢复默认 sink）
	# Debian 上 /etc/xdg/systemd/user 可能与 /etc/systemd/user 为同一目录（symlink），
	# 直接 cp 会报 "are the same file"。
	install -d rootdir/etc/xdg/systemd/user
	_rdp_src=rootdir/etc/systemd/user/raphael-rdp-audio-watch.service
	_rdp_dst=rootdir/etc/xdg/systemd/user/raphael-rdp-audio-watch.service
	if [ ! "$_rdp_src" -ef "$_rdp_dst" ]; then
		cp "$_rdp_src" "$_rdp_dst"
	fi
	unset _rdp_src _rdp_dst

	# NEVER put raphael-audio-setup in wireplumber ExecStartPost:
	# setup used to restart WP while WP was still "starting" → 90s TimeoutStartSec
	# deadlock and audio only appears after login ~1.5min late.
	rm -f rootdir/etc/systemd/user/wireplumber.service.d/raphael-audio.conf
	rmdir rootdir/etc/systemd/user/wireplumber.service.d 2>/dev/null || true

	install -d rootdir/etc/systemd/user/default.target.wants
	ln -sf /etc/systemd/user/raphael-audio-setup.service \
		rootdir/etc/systemd/user/default.target.wants/raphael-audio-setup.service
	ln -sf /etc/systemd/user/raphael-headset-switch.service \
		rootdir/etc/systemd/user/default.target.wants/raphael-headset-switch.service
	ln -sf /etc/systemd/user/raphael-rdp-audio-watch.service \
		rootdir/etc/systemd/user/default.target.wants/raphael-rdp-audio-watch.service

	for unit in pipewire.socket pipewire-pulse.socket pipewire.service \
	            pipewire-pulse.service wireplumber.service \
	            pipewire-media-session.service; do
		chroot rootdir systemctl --global unmask "$unit" 2>/dev/null || true
	done
	chroot rootdir systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
	chroot rootdir systemctl --global enable \
	    pipewire.socket pipewire-pulse.socket wireplumber.service \
	    raphael-audio-setup.service raphael-headset-switch.service \
	    raphael-rdp-audio-watch.service 2>/dev/null || true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06b] ✅ 音频配置完成"
