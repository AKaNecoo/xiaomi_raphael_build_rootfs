#!/bin/bash
# Raphael SLPI DIAG：通过 deb 安装
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEB_DIR="${SENSOR_DEB_DIR:-$SCRIPT_DIR/../debs}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d] 📋 安装 DIAG deb"

install_one() {
	local pattern="$1"
	local deb
	deb="$(ls -1v "$DEB_DIR"/$pattern 2>/dev/null | tail -1)" || true
	if [ -z "$deb" ]; then
		echo "[10d] ❌ 缺少: $DEB_DIR/$pattern" >&2
		exit 1
	fi
	mkdir -p rootdir/tmp/diag-pkgs
	cp "$deb" rootdir/tmp/diag-pkgs/
	chroot rootdir dpkg -i "/tmp/diag-pkgs/$(basename "$deb")" || \
		chroot rootdir dpkg -i --force-depends "/tmp/diag-pkgs/$(basename "$deb")"
}

install_one 'diag-router_*_arm64.deb'
install_one 'diag-xiaomi-raphael_*_arm64.deb'

chroot rootdir apt-get install -f -y
rm -rf rootdir/tmp/diag-pkgs

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10d] ✅ DIAG deb 安装完成"
