#!/bin/bash
# Raphael SLPI 传感器栈：通过 deb 安装
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

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10c] ✅ 传感器 deb 安装完成"
