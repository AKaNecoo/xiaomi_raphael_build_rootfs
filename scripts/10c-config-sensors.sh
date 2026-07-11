#!/bin/bash
# Raphael SLPI 传感器栈：通过 deb 安装（安装后校验关键文件非空）
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="${SENSOR_DEB_DIR:-$SCRIPT_DIR/../debs}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10c] 📡 安装传感器 runtime deb"

install_one() {
	local pattern="$1"
	local deb
	deb="$(ls -1v "$DEB_DIR"/$pattern 2>/dev/null | tail -1)" || true
	if [ -z "$deb" ]; then
		echo "[10c] ❌ 缺少: $DEB_DIR/$pattern" >&2
		echo "    构建: xiaomi_raphael_build_kernel/raphael-sensors_build.sh" >&2
		echo "    同步: xiaomi_raphael_build_kernel/scripts/sync-debs-to-rootfs.sh" >&2
		exit 1
	fi
	echo "[10c]   └─ $(basename "$deb")"
	mkdir -p rootdir/tmp/sensor-pkgs
	cp "$deb" rootdir/tmp/sensor-pkgs/
	chroot rootdir dpkg -i "/tmp/sensor-pkgs/$(basename "$deb")" || \
		chroot rootdir dpkg -i --force-depends "/tmp/sensor-pkgs/$(basename "$deb")"
}

# hexagonrpcd / libssc / iio 由 06 安装；此处装 runtime + tools
install_one 'sensors-xiaomi-raphael_*_arm64.deb'
install_one 'sensors-tools-xiaomi-raphael_*_arm64.deb'

chroot rootdir apt-get install -f -y
rm -rf rootdir/tmp/sensor-pkgs

# 防止 rootfs 里出现 0 字节 stub（会导致开机 Exec format error，错过 SLPI 40s 窗口）
fail=0
for f in \
	usr/libexec/raphael-hexagonrpcd-pre.sh \
	etc/systemd/system/hexagonrpcd-sdsp.path \
	etc/udev/rules.d/10-fastrpc.rules \
	etc/systemd/system/hexagonrpcd-sdsp.service.d/trigger-on-device.conf; do
	if [ ! -s "rootdir/$f" ]; then
		echo "[10c] ❌ 安装后文件为空或缺失: /$f" >&2
		fail=1
	else
		echo "[10c]   └─ OK /$f ($(wc -c < "rootdir/$f") bytes)"
	fi
done
# path 被 mask 成指向 /dev/null 的符号链接时，刷机后会变成空文件
if [ -L rootdir/etc/systemd/system/hexagonrpcd-sdsp.path ]; then
	echo "[10c] ❌ hexagonrpcd-sdsp.path 是符号链接（可能被 mask→/dev/null），拒绝打包" >&2
	ls -la rootdir/etc/systemd/system/hexagonrpcd-sdsp.path >&2
	fail=1
fi
if [ "$fail" -ne 0 ]; then
	exit 1
fi

# 确保 path 已 enable（不依赖 chroot 里 systemctl 完全可用）
mkdir -p rootdir/etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/hexagonrpcd-sdsp.path \
	rootdir/etc/systemd/system/multi-user.target.wants/hexagonrpcd-sdsp.path
chmod 0755 rootdir/usr/libexec/raphael-hexagonrpcd-pre.sh

# iio 早于 GDM：保证 Mutter PanelOrientationManaged，GNOME 自带自动旋转按钮可用
mkdir -p rootdir/etc/systemd/system/iio-sensor-proxy.service.d
if [ -f rootdir/etc/systemd/system/iio-sensor-proxy.service.d/qrtr.conf ]; then
	echo "[10c]   └─ iio-sensor-proxy early-start drop-in present"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10c] ✅ 传感器 deb 安装完成"
