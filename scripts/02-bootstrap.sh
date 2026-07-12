#!/bin/bash
set -e

DEBIAN_VERSION="${DEBIAN_VERSION:-trixie}"
UBUNTU_VERSION="${UBUNTU_VERSION:-resolute}"
BOOT_IMG="${BOOT_IMG:-xiaomi-k20pro-boot.img}"
EFI_IMG="${EFI_IMG:-xiaomi-k20pro-efi.img}"
SYSTEM_TYPE="${SYSTEM_TYPE:-ubuntu-server}"
BOOTSTRAP_TOOL="${BOOTSTRAP_TOOL:-mmdebstrap}"
ARCH="${ARCH:-arm64}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] 🚀 安装基础系统 (目标架构: $ARCH)"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 主机架构: $(uname -m)"

if [[ "$SYSTEM_TYPE" == *"debian-"* ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 使用 $BOOTSTRAP_TOOL 构建 Debian $DEBIAN_VERSION 🐧"
    OS_VERSION="$DEBIAN_VERSION"
    MIRROR="http://deb.debian.org/debian/"
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 使用 $BOOTSTRAP_TOOL 构建 Ubuntu $UBUNTU_VERSION 🦁"
    OS_VERSION="$UBUNTU_VERSION"
    MIRROR="http://ports.ubuntu.com/ubuntu-ports/"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 开始 bootstrap (这可能需要几分钟...)"
if [ "$BOOTSTRAP_TOOL" = "mmdebstrap" ]; then
    # ForceIPv4：GHA 等环境常无可用 IPv6，否则 mirror AAAA 失败
    mmdebstrap --arch="$ARCH" --aptopt='Acquire::ForceIPv4 "true"' \
        "$OS_VERSION" rootdir "$MIRROR"
elif [ "$BOOTSTRAP_TOOL" = "debootstrap" ]; then
    debootstrap --arch=$ARCH $OS_VERSION rootdir $MIRROR
else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: 不支持的构建工具: $BOOTSTRAP_TOOL"
    exit 1
fi

if [ ! -f "${BOOT_IMG}" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: ${BOOT_IMG} 不存在"
    exit 1
fi
if [ ! -f "${EFI_IMG}" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: ${EFI_IMG} 不存在"
    exit 1
fi

mkdir -p rootdir/boot efidir

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 挂载 /boot 分区 (vendor, ext4, ${BOOT_IMG}) 📁"
if ! mount -o loop ${BOOT_IMG} rootdir/boot; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: /boot 分区挂载失败"
    exit 1
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 挂载 EFI 分区 (cust, FAT, ${EFI_IMG}) 📁"
if ! mount -o loop ${EFI_IMG} efidir; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: EFI 分区挂载失败"
    exit 1
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02]   └─ 部署引导文件 (EFI/BOOT -> cust, Linux -> vendor /boot)"
# U-Boot bootefi bootmgr / remamed rEFInd 需要标准路径 EFI/BOOT/BOOTAA64.EFI
# （旧布局 /boot/BOOTAA64.EFI 不会被识别）
cp -R ./boot/efi/. efidir/
if [ ! -f efidir/EFI/BOOT/BOOTAA64.EFI ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ❌ 错误: 缺少 efidir/EFI/BOOT/BOOTAA64.EFI"
    exit 1
fi
if [ -f ./boot/refind_linux.conf ]; then
    cp ./boot/refind_linux.conf rootdir/boot/
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [02] ✅ 基础系统安装完成"
