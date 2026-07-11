#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"
QCOM_DEB_DIR="${QCOM_DEB_DIR:-$SCRIPT_DIR/../debs}"
SENSOR_DEB_DIR="${SENSOR_DEB_DIR:-$SCRIPT_DIR/../debs}"

. "$CONFIG_DIR/build-config.sh"

SYSTEM_TYPE="${SYSTEM_TYPE:-ubuntu-server}"
DESKTOP_ENV="${DESKTOP_ENV:-}"
DEBIAN_VERSION="${DEBIAN_VERSION:-trixie}"
UBUNTU_VERSION="${UBUNTU_VERSION:-resolute}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] 📦 安装软件包"

export DEBIAN_FRONTEND=noninteractive

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 更新系统包..."
chroot rootdir apt-get update
chroot rootdir apt-get upgrade -y

BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano gpgv gnupg gpgv2 grub2-common ca-certificates kmod debconf wireless-regdb less procps psmisc iputils-ping systemd udev dbus net-tools rfkill wireless-tools network-manager initramfs-tools chrony curl wget locales tzdata iproute2 zram-tools"

if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then 
   BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager systemd-boot initramfs-tools chrony curl wget locales tzdata fonts-wqy-microhei dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
elif [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
	if [[ "$SYSTEM_TYPE" == *"server"* ]]; then
		BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager net-tools initramfs-tools chrony curl wget locales tzdata dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
	else
		BASE_PACKAGES="bash-completion sudo apt-utils ssh openssh-server nano network-manager net-tools grub-efi-arm64-signed initramfs-tools chrony curl wget locales tzdata dnsmasq iptables iproute2 zram-tools udev dbus kmod ca-certificates wireless-regdb"
	fi
fi

# Modem/QCOM 本地 deb（libqrtr、rmtfs、MM 等）在 rootfs/debs/
# 传感器交叉编译 deb 在 xiaomi_raphael_build_kernel/output/
# iio-sensor-proxy 由本地 SSC 版 deb 安装（见 install_sensor_local_debs），勿用 apt 无 SSC 版
DEVICE_PACKAGES="wpasupplicant iw iproute2 alsa-ucm-conf alsa-utils power-profiles-daemon gpsd gpsd-clients libmbim-utils liblzma5"


if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    case "$DESKTOP_ENV" in
        "gnome")
            if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
                DESKTOP_PACKAGES="ubuntu-desktop"
            elif [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
                DESKTOP_PACKAGES="gnome"
            fi
            ;;
        "phosh-core")
            DESKTOP_PACKAGES="phosh-core"
            ;;
        "phosh-full")
            DESKTOP_PACKAGES="phosh-full"
            ;;
        "phosh-phone")
            DESKTOP_PACKAGES="phosh-phone"
            ;;
        *)
            DESKTOP_PACKAGES=""
            ;;
    esac
else
    DESKTOP_PACKAGES=""
fi

# Plymouth provides the vendor boot-logo animation (script.so plugin, drm /
# frame-buffer renderers and the initramfs hook). Installed for every variant
# (incl. server) so the splash works; the theme itself is set up in
# 08b-config-plymouth.sh before the initramfs is generated in 09.
PLYMOUTH_PACKAGES="plymouth plymouth-themes plymouth-label"

ALL_PACKAGES="$BASE_PACKAGES $DEVICE_PACKAGES $DESKTOP_PACKAGES $PLYMOUTH_PACKAGES"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 基础包: $(echo "$BASE_PACKAGES" | tr ' ' ', ')"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 设备包: $(echo "$DEVICE_PACKAGES" | tr ' ' ', ')"
if [ -n "$DESKTOP_PACKAGES" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 桌面包: $(echo "$DESKTOP_PACKAGES" | tr ' ' ', ')"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 开始安装（这可能需要几分钟...）"
chroot rootdir apt-get install -y $ALL_PACKAGES
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 修复 Debian dpkg 错误"
    chroot rootdir dpkg --remove --force-remove-reinstreq shim-signed 2>/dev/null || true
    chroot rootdir dpkg --purge shim-signed 2>/dev/null || true
    chroot rootdir dpkg --configure -a 2>/dev/null || true
    chroot rootdir apt-get -f install -y 2>/dev/null || true
fi

install_qcom_local_debs() {
	local deb_dir="$1"
	local required=(
		libqrtr1_*_arm64.deb
		qrtr-tools_*_arm64.deb
		rmtfs_*_arm64.deb
		protection-domain-mapper_*_arm64.deb
		tqftpserv_*_arm64.deb
		audioreach-topology_*_all.deb
		modemmanager-qrtr-sm8150_*_jammy_arm64.deb
	)

	if [ ! -d "$deb_dir" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ deb 目录不存在: $deb_dir" >&2
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]    请先运行: $SCRIPT_DIR/docker-build.sh" >&2
		exit 1
	fi

	local missing=0
	for pattern in "${required[@]}"; do
		if ! compgen -G "$deb_dir/$pattern" >/dev/null; then
			echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 缺少: $deb_dir/$pattern" >&2
			missing=1
		fi
	done
	if [ "$missing" -ne 0 ]; then
		exit 1
	fi

	local mm_deb
	mm_deb="$(ls -1 "$deb_dir"/modemmanager-qrtr-sm8150_*_jammy_arm64.deb 2>/dev/null | sort -V | tail -1)"
	if [ -z "$mm_deb" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 缺少: $deb_dir/modemmanager-qrtr-sm8150_*_jammy_arm64.deb" >&2
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]    请先运行: 基带测试/mm/mm 下 ./build.sh && ./make-deb.sh，并复制 deb 到 debs/" >&2
		exit 1
	fi
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ ModemManager: $(basename "$mm_deb") (QMAPv4 patch, 禁用 v5)"

chroot rootdir sh -c "apt-get remove -y --allow-remove-essential \
	modemmanager libqmi-utils libqmi-proxy libqmi-glib5"
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装本地 Qualcomm deb: $deb_dir"
	mkdir -p rootdir/tmp/qcom-debs
	# 按依赖顺序：libqrtr1 -> tools/rmtfs/pd-mapper/tqftpserv -> topology -> MM
	cp "$deb_dir"/libqrtr1_*_arm64.deb rootdir/tmp/qcom-debs/
	cp "$deb_dir"/qrtr-tools_*_arm64.deb \
		"$deb_dir"/rmtfs_*_arm64.deb \
		"$deb_dir"/protection-domain-mapper_*_arm64.deb \
		"$deb_dir"/tqftpserv_*_arm64.deb \
		"$deb_dir"/audioreach-topology_*_all.deb \
		rootdir/tmp/qcom-debs/
	cp "$mm_deb" rootdir/tmp/qcom-debs/

	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/libqrtr1_*_arm64.deb"
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/qrtr-tools_*_arm64.deb \
		/tmp/qcom-debs/rmtfs_*_arm64.deb \
		/tmp/qcom-debs/protection-domain-mapper_*_arm64.deb \
		/tmp/qcom-debs/tqftpserv_*_arm64.deb"
	chroot rootdir sh -c '
		export DEBIAN_FRONTEND=noninteractive
		dpkg -i --auto-deconfigure /tmp/qcom-debs/modemmanager-qrtr-sm8150_*.deb
		apt-get install -f -y
	'
	chroot rootdir sh -c "dpkg -i /tmp/qcom-debs/audioreach-topology_*_all.deb"
	chroot rootdir apt-get install -f -y
	rm -rf rootdir/tmp/qcom-debs

	mkdir -p rootdir/var/lib/rmtfs

	# qrtr-ns 在 lib/systemd/system；rmtfs/pd-mapper 在 usr/lib/systemd/system
	chroot rootdir systemctl enable qrtr-ns.service
	chroot rootdir systemctl disable rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl mask rmtfs-dir.service 2>/dev/null || true
	chroot rootdir systemctl unmask rmtfs.service 2>/dev/null || true
	#chroot rootdir systemctl enable rmtfs-dir.service pd-mapper.service tqftpserv.service
	chroot rootdir systemctl enable rmtfs.service pd-mapper.service tqftpserv.service
	# 避免与 rmtfs 主服务竞态（与 Debian 打包策略一致）

}

install_qcom_local_debs "$QCOM_DEB_DIR"

install_sensor_local_debs() {
	local deb_dir="$1"
	local required=(
		hexagonrpcd_*_arm64.deb
		libssc0_*_arm64.deb
		iio-sensor-proxy_*_arm64.deb
	)

	if [ ! -d "$deb_dir" ]; then
		echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ deb 目录不存在: $deb_dir" >&2
		exit 1
	fi

	local missing=0
	for pattern in "${required[@]}"; do
		if ! compgen -G "$deb_dir/$pattern" >/dev/null; then
			echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 缺少: $deb_dir/$pattern" >&2
			echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]    请先运行: xiaomi_raphael_build_kernel/raphael-sensors_build.sh" >&2
			missing=1
		fi
	done
	if [ "$missing" -ne 0 ]; then
		exit 1
	fi

	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装本地传感器 deb (SSC): $deb_dir"
	mkdir -p rootdir/tmp/sensor-debs
	# 优先最新版本号（避免同时存在 -1/-2 时 dpkg -i 装到旧包）
	cp "$(ls -1v "$deb_dir"/libssc0_*_arm64.deb | tail -1)" \
		"$(ls -1v "$deb_dir"/hexagonrpcd_*_arm64.deb | tail -1)" \
		"$(ls -1v "$deb_dir"/iio-sensor-proxy_*_arm64.deb | tail -1)" \
		rootdir/tmp/sensor-debs/

	# 替换 Ubuntu 自带的无 SSC 版 iio-sensor-proxy
	chroot rootdir apt-get remove -y iio-sensor-proxy 2>/dev/null || true

	chroot rootdir sh -c "dpkg -i /tmp/sensor-debs/libssc0_*_arm64.deb"
	chroot rootdir sh -c "dpkg -i /tmp/sensor-debs/hexagonrpcd_*_arm64.deb"
	chroot rootdir sh -c "dpkg -i /tmp/sensor-debs/iio-sensor-proxy_*_arm64.deb"
	chroot rootdir apt-get install -f -y
	rm -rf rootdir/tmp/sensor-debs
}

install_sensor_local_debs "$SENSOR_DEB_DIR"

# 修改服务配置
if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service 2>/dev/null || true
fi

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [ "$DESKTOP_ENV" = "gnome" ]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置 GDM 自动登录"
        cat > rootdir/etc/gdm3/custom.conf << 'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=user
EOF
		chroot rootdir systemctl disable brltty.service
		chroot rootdir systemctl mask brltty.service
        #chroot rootdir gsettings set org.gnome.mutter auto-rotate-screen true || true

        # Ubuntu 的 apt firefox 只是指向 snap 的过渡空壳，chroot 构建无 snapd
        # → 无图标/无任务栏。按 Mozilla 官方文档改用 packages.mozilla.org 提供的
        # 原生 deb（amd64/arm64），并用 apt pin 强制优先、把 Ubuntu 的 snap 壳降权。
        # 参考: https://support.mozilla.org/zh-CN/kb/install-firefox-linux
        if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then
            FIREFOX_ARCH="$(chroot rootdir dpkg --print-architecture)"
            # Mozilla 官方源仅发布 amd64/arm64 的 firefox deb
            if [[ "$FIREFOX_ARCH" != "amd64" && "$FIREFOX_ARCH" != "arm64" ]]; then
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ⚠️ Mozilla 官方源无 ${FIREFOX_ARCH} 的 firefox deb，跳过 Firefox 安装"
            else
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 Firefox (Mozilla 官方 deb, 非 snap)"

                # 1) 导入 Mozilla APT 仓库签名密钥
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置 Mozilla 官方 APT 源 (packages.mozilla.org)"
                install -d -m 0755 rootdir/etc/apt/keyrings
                curl -fsSL https://packages.mozilla.org/apt/repo-signing-key.gpg \
                    -o rootdir/etc/apt/keyrings/packages.mozilla.org.asc
                if [ ! -s rootdir/etc/apt/keyrings/packages.mozilla.org.asc ]; then
                    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ Mozilla 签名密钥获取失败，终止构建"
                    exit 1
                fi
                chmod 0644 rootdir/etc/apt/keyrings/packages.mozilla.org.asc

                # 2) 校验密钥指纹，防止源被篡改/中间人
                MOZ_FPR_EXPECT="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
                MOZ_GPGHOME="$(mktemp -d)"
                MOZ_FPR_GOT="$(GNUPGHOME="$MOZ_GPGHOME" gpg -n -q --import --import-options import-show \
                    rootdir/etc/apt/keyrings/packages.mozilla.org.asc 2>/dev/null \
                    | grep -ioE "[0-9A-F]{40}" | head -1)"
                rm -rf "$MOZ_GPGHOME"
                if [ "$MOZ_FPR_GOT" != "$MOZ_FPR_EXPECT" ]; then
                    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ Mozilla 密钥指纹不匹配 (得到: ${MOZ_FPR_GOT:-空})，终止构建"
                    exit 1
                fi

                # 3) DEB822 源（suite 固定为 mozilla，不依赖发行代号，jammy~resolute 通用）
                cat > rootdir/etc/apt/sources.list.d/mozilla.sources << EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Architectures: ${FIREFOX_ARCH}
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

                # 4) 优先 Mozilla 源，并把 Ubuntu 的 snap 过渡 firefox 降权（避免被换回壳）
                cat > rootdir/etc/apt/preferences.d/mozilla << 'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF

                chroot rootdir apt-get update
                chroot rootdir apt-get remove -y firefox 2>/dev/null || true
                chroot rootdir apt-get install -y firefox

                if ! chroot rootdir dpkg -s firefox >/dev/null 2>&1; then
                    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ firefox 未安装成功，终止构建"
                    exit 1
                fi

                # Mozilla 的 firefox deb 自带 /usr/share/applications/firefox.desktop
                # (Exec=firefox, Icon=firefox, StartupWMClass=firefox)，无需自定义。
                # 复制到 skel/Desktop 作为桌面图标。
                install -d rootdir/etc/skel/Desktop
                if [ -f rootdir/usr/share/applications/firefox.desktop ]; then
                    cp rootdir/usr/share/applications/firefox.desktop \
                       rootdir/etc/skel/Desktop/firefox.desktop
                    chmod 755 rootdir/etc/skel/Desktop/firefox.desktop
                fi

                # 写入 ubuntu-dock 默认收藏（含 Firefox），首次登录即固定到任务栏
                install -d rootdir/etc/dconf/db/local.d rootdir/etc/dconf/profile
                cat > rootdir/etc/dconf/db/local.d/01-firefox-favorite << 'EOF'
[org/gnome/shell]
favorite-apps=['firefox.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Software.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Calculator.desktop', 'org.gnome.Terminal.desktop', 'gnome-control-center.desktop']

[org/gnome/desktop/default-applications/web]
browser='firefox.desktop'
EOF
                cat > rootdir/etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
                chroot rootdir dconf update 2>/dev/null || true
                echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ Firefox (Mozilla 官方 deb) 已配置 ✅"
            fi
        fi
    fi
fi

# K20 专属 ALSA UCM 声卡路由配置：设备声音正常的关键（依赖 alsa-ucm-conf）。
# 用 apt-get install ./deb 安装以自动解析依赖（dpkg -i 不解析依赖会留下未配置状态）。
# 桌面镜像若提供了该 deb 却装不上，直接终止构建——否则出来的镜像声音异常。
if [ -f "alsa-xiaomi-raphael.deb" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 安装 ALSA 配置 (alsa-xiaomi-raphael)"
    cp alsa-xiaomi-raphael.deb rootdir/tmp/
    chroot rootdir apt-get install -y /tmp/alsa-xiaomi-raphael.deb \
        || chroot rootdir sh -c 'dpkg -i /tmp/alsa-xiaomi-raphael.deb; apt-get install -fy'
    rm rootdir/tmp/alsa-xiaomi-raphael.deb

    if ! chroot rootdir dpkg -s alsa-xiaomi-raphael >/dev/null 2>&1; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ alsa-xiaomi-raphael 未安装成功，设备声音会异常，终止构建"
        exit 1
    fi
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ alsa-xiaomi-raphael 已安装 ✅"
elif [[ "$SYSTEM_TYPE" == *"phosh"* || "$SYSTEM_TYPE" == *"gnome"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ❌ 桌面镜像缺少 alsa-xiaomi-raphael.deb，设备声音会异常，终止构建"
    exit 1
fi

# ================================================================
# 音频：Raphael TFA9874 软件音量（保留 PipeWire，兼容远程桌面）
# ----------------------------------------------------------------
# TFA9874 扬声器在 UCM 中无 HW 音量控件，PipeWire 默认 HW mixer → 几乎无声。
# 通过 WirePlumber soft-mixer 修复音量，同时保留 PipeWire 栈供 GNOME 远程桌面/
# 屏幕共享（依赖 pipewire + portal）使用。
# 切勿 mask PipeWire 改 PulseAudio——会破坏 gnome-remote-desktop / RDP。
# ================================================================
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 配置音频 (PipeWire soft-mixer，保留远程桌面)"

PW_CANDIDATES="pipewire pipewire-pulse pipewire-audio pipewire-alsa \
    pipewire-audio-client-libraries libspa-0.2-bluetooth wireplumber"
PW_INSTALL=""
for p in $PW_CANDIDATES; do
    if chroot rootdir apt-cache show "$p" >/dev/null 2>&1; then
        PW_INSTALL="$PW_INSTALL $p"
    fi
done
if [ -n "$PW_INSTALL" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 确保 PipeWire 包:$PW_INSTALL"
    chroot rootdir apt-get install -y $PW_INSTALL
fi

install -d rootdir/etc/wireplumber/wireplumber.conf.d
cat > rootdir/etc/wireplumber/wireplumber.conf.d/50-raphael-soft-mixer.conf << 'EOF'
# Raphael (TFA9874): no ALSA HW volume in UCM → force software mixer.
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.*" } ]
    actions = {
      update-props = {
        api.alsa.soft-mixer = true
        api.alsa.use-ucm = true
      }
    }
  }
]
monitor.rules = [
  {
    matches = [ { node.name = "~alsa_output.*" } ]
    actions = {
      update-props = {
        volume = 1.0
      }
    }
  }
]
EOF

# 若旧镜像曾 mask PipeWire 改 PulseAudio，此处恢复（远程桌面需要 PipeWire）
for unit in pipewire.socket pipewire-pulse.socket pipewire.service \
            pipewire-pulse.service wireplumber.service \
            pipewire-media-session.service; do
    chroot rootdir systemctl --global unmask "$unit" 2>/dev/null || true
done
chroot rootdir systemctl --global mask pulseaudio.service pulseaudio.socket 2>/dev/null || true
chroot rootdir systemctl --global enable \
    pipewire.socket pipewire-pulse.socket wireplumber.service 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 音频配置完成 ✅"

if [[ "$SYSTEM_TYPE" != *"server"* ]]; then
    if [[ "$DESKTOP_ENV" == phosh* ]]; then
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06]   └─ 启用 Phosh 服务"
        chroot rootdir systemctl enable phosh
    fi
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [06] ✅ 软件包安装完成"
