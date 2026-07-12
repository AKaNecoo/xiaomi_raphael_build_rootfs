#!/bin/bash
set -e

# ================================================================
# [13c] GNOME 远程登录 (Remote Login / RDP)
# ----------------------------------------------------------------
# 目标：系统级 RDP → GDM 登录界面 → 独立远程会话（不是桌面共享）。
#
# 需要系统级 Remote Login（grdctl --system），大致对应：
#   Ubuntu noble+ / Debian trixie+（GNOME 46+）
# jammy / bookworm 只有会话内桌面共享，本脚本直接跳过。
#
# Ubuntu Noble (gnome-remote-desktop 46.x) 已知包装缺陷：
# handover daemon 未装到 greeter/xdg autostart，且
# X-GNOME-HiddenUnderSystemd=true 会挡住启动 → Aborting handover。
# 见 LP:#2154408。本脚本写入无 HiddenUnderSystemd 的 autostart。
#
# 依赖同栈音频(06b 新版 GNOME 路径)：PipeWire 勿被 mask；否则投屏
# 报 Couldn't connect pipewire context。与桌面共享无关。
#
# 客户端若开启「远程音频 / 在此计算机上播放」，会话里会出现虚拟输出
# (auto_null)。06b 的 raphael-rdp-audio-watch 在 RDP 断开后自动拉回
# HiFi Speaker；会话进行中不干预。请仍在客户端改为「在远程计算机上播放」
# （grd 服务端无独立开关）。WCD 被打挂后只能重启恢复。
# ================================================================

if [ "$DESKTOP_ENV" != "gnome" ]; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] ⏭️  非 GNOME，跳过远程桌面"
	exit 0
fi

_skip_remote_login=false
case "${UBUNTU_VERSION:-}" in
	jammy|focal) _skip_remote_login=true ;;
esac
case "${DEBIAN_VERSION:-}" in
	bookworm|bullseye) _skip_remote_login=true ;;
esac
if [ "$_skip_remote_login" = true ]; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] ⏭️  ${UBUNTU_VERSION:-$DEBIAN_VERSION} 无系统 Remote Login，跳过"
	exit 0
fi

RDP_USER="${USER_NAME:-user}"
RDP_PASS="${USER_PASS:-1234}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] 🖥️ 配置 GNOME 远程登录 Remote Login (RDP: ${RDP_USER})"

if ! chroot rootdir apt-cache show gnome-remote-desktop >/dev/null 2>&1; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] ⏭️  无 gnome-remote-desktop 包，跳过"
	exit 0
fi

PKGS=""
for p in gnome-remote-desktop openssl gdm3; do
	if chroot rootdir apt-cache show "$p" >/dev/null 2>&1; then
		PKGS="$PKGS $p"
	fi
done
chroot rootdir apt-get install -y $PKGS || true

if ! chroot rootdir dpkg -s gnome-remote-desktop >/dev/null 2>&1; then
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] ⚠️  gnome-remote-desktop 未装上，跳过"
	exit 0
fi

# LP:#2154408 — handover must autostart in greeter + user sessions
# (no X-GNOME-HiddenUnderSystemd — that flag blocks GDM-created sessions)
HANDOVER_DESKTOP='[Desktop Entry]
Type=Application
Name=GNOME Remote Desktop Handover Daemon
Exec=/usr/libexec/gnome-remote-desktop-daemon --handover
Terminal=false
NoDisplay=true
X-GNOME-AutoRestart=true
'
install -d rootdir/usr/share/gdm/greeter/autostart
install -d rootdir/etc/xdg/autostart
printf '%s\n' "$HANDOVER_DESKTOP" \
	> rootdir/usr/share/gdm/greeter/autostart/org.gnome.RemoteDesktop.Handover.desktop
printf '%s\n' "$HANDOVER_DESKTOP" \
	> rootdir/etc/xdg/autostart/org.gnome.RemoteDesktop.Handover.desktop

# Prefer autostart over systemd user unit (avoids dual-manage / SIGTERM race)
rm -f rootdir/etc/systemd/user/gnome-session.target.wants/gnome-remote-desktop-handover.service
chroot rootdir systemctl --global disable gnome-remote-desktop-handover.service 2>/dev/null || true
# Drop Desktop Sharing leftovers from older builds
rm -f rootdir/etc/systemd/user/default.target.wants/raphael-desktop-sharing.service
rm -f rootdir/etc/systemd/user/raphael-desktop-sharing.service
rm -f rootdir/usr/local/sbin/raphael-enable-desktop-sharing.sh
chroot rootdir systemctl --global disable gnome-remote-desktop.service 2>/dev/null || true

# GDM: Remote Login needs greeter; AutomaticLogin fights handover
# (overrides AutomaticLoginEnable=true written in 06)
install -d rootdir/etc/gdm3
cat > rootdir/etc/gdm3/custom.conf << 'EOF'
# Remote Login needs GDM greeter for remote displays.
# AutomaticLogin must stay off or GDM_IS_REMOTE_DISPLAY handover breaks.
[daemon]
AutomaticLoginEnable=false
# AutomaticLogin=user
WaylandEnable=true
EOF

# Pre-seed TLS certs so first-boot oneshot does not race openssl
GRD_HOME_IMG=rootdir/var/lib/gnome-remote-desktop
CERT_DIR_IMG="$GRD_HOME_IMG/.local/share/gnome-remote-desktop"
install -d "$CERT_DIR_IMG"
if [ ! -f "$CERT_DIR_IMG/rdp-tls.crt" ] || [ ! -f "$CERT_DIR_IMG/rdp-tls.key" ]; then
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
		-keyout "$CERT_DIR_IMG/rdp-tls.key" -out "$CERT_DIR_IMG/rdp-tls.crt" \
		-subj "/CN=xiaomi-raphael/O=Raphael Linux" >/dev/null 2>&1
fi
chmod 600 "$CERT_DIR_IMG/rdp-tls.key"
# Ownership applied on device (gnome-remote-desktop user exists after package install)
chroot rootdir chown -R gnome-remote-desktop:gnome-remote-desktop /var/lib/gnome-remote-desktop 2>/dev/null || true

install -d rootdir/usr/local/sbin
cat > rootdir/usr/local/sbin/raphael-enable-remote-login.sh << EOF
#!/bin/bash
# Configure GNOME Remote Login (system daemon), NOT desktop sharing.
set -euo pipefail
RDP_USER="\${RDP_USER:-${RDP_USER}}"
RDP_PASS="\${RDP_PASS:-${RDP_PASS}}"

if ! command -v grdctl >/dev/null 2>&1; then
	echo "raphael-enable-remote-login: grdctl missing" >&2
	exit 1
fi

# Desktop Sharing must not own 3389
for u in \$(awk -F: '\$3>=1000 && \$3<65534 {print \$1}' /etc/passwd 2>/dev/null); do
	uid=\$(id -u "\$u" 2>/dev/null || true)
	[ -n "\$uid" ] || continue
	runtime="/run/user/\$uid"
	if [ -S "\$runtime/bus" ]; then
		sudo -u "\$u" env XDG_RUNTIME_DIR="\$runtime" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=\$runtime/bus" \
			gsettings set org.gnome.desktop.remote-desktop.rdp enable false 2>/dev/null || true
		sudo -u "\$u" env XDG_RUNTIME_DIR="\$runtime" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=\$runtime/bus" \
			grdctl rdp disable 2>/dev/null || true
		sudo -u "\$u" systemctl --user stop gnome-remote-desktop.service 2>/dev/null || true
		sudo -u "\$u" systemctl --user disable gnome-remote-desktop.service 2>/dev/null || true
		sudo -u "\$u" systemctl --user disable gnome-remote-desktop-handover.service 2>/dev/null || true
	fi
done

GRD_HOME=\$(getent passwd gnome-remote-desktop | cut -d: -f6)
[ -n "\$GRD_HOME" ] || GRD_HOME=/var/lib/gnome-remote-desktop
CERT_DIR="\$GRD_HOME/.local/share/gnome-remote-desktop"
CERT="\$CERT_DIR/rdp-tls.crt"
KEY="\$CERT_DIR/rdp-tls.key"
mkdir -p "\$CERT_DIR"
if [ ! -f "\$CERT" ] || [ ! -f "\$KEY" ]; then
	openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \\
		-keyout "\$KEY" -out "\$CERT" \\
		-subj "/CN=xiaomi-raphael/O=Raphael Linux" >/dev/null 2>&1
fi
chown -R gnome-remote-desktop:gnome-remote-desktop "\$GRD_HOME" 2>/dev/null || true
chmod 600 "\$KEY" 2>/dev/null || true

grdctl --system rdp set-tls-cert "\$CERT"
grdctl --system rdp set-tls-key "\$KEY"
grdctl --system rdp set-credentials "\$RDP_USER" "\$RDP_PASS"
grdctl --system rdp enable

# Headless encode / EGL 可能访问 render 节点
usermod -aG render,video gnome-remote-desktop 2>/dev/null || true

systemctl enable gnome-remote-desktop.service
# Avoid bouncing an already-healthy listener (drops active Remote Login)
if systemctl is-active --quiet gnome-remote-desktop.service; then
	systemctl reload-or-restart gnome-remote-desktop.service 2>/dev/null || true
else
	systemctl start gnome-remote-desktop.service
fi
EOF
chmod 755 rootdir/usr/local/sbin/raphael-enable-remote-login.sh

# First boot: apply system RDP credentials + enable daemon
install -d rootdir/etc/systemd/system
cat > rootdir/etc/systemd/system/raphael-enable-remote-login.service << 'EOF'
[Unit]
Description=Raphael enable GNOME Remote Login (system RDP)
After=network-online.target gdm.service
Wants=network-online.target gdm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-enable-remote-login.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

install -d rootdir/etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/raphael-enable-remote-login.service \
	rootdir/etc/systemd/system/multi-user.target.wants/raphael-enable-remote-login.service

chroot rootdir systemctl enable gnome-remote-desktop.service 2>/dev/null || true
chroot rootdir systemctl enable raphael-enable-remote-login.service 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13c] ✅ 远程登录配置完成 (系统 RDP :3389 + handover autostart)"
