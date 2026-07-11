#!/bin/bash
set -e

IMAGE_SIZE="${IMAGE_SIZE:-3G}"
IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
BOOT_NAME="${BOOT_NAME:-xiaomi-k20pro-boot.img}"
BOOT_SIZE="${BOOT_SIZE:-512M}"
EFI_NAME="${EFI_NAME:-xiaomi-k20pro-efi.img}"
EFI_SIZE="${EFI_SIZE:-128M}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] 📦 创建根文件系统镜像 (${IMAGE_SIZE})"

truncate -s ${IMAGE_SIZE} ${IMAGE_NAME}
mkfs.ext4 ${IMAGE_NAME}
mkdir -p rootdir
mount -o loop ${IMAGE_NAME} rootdir
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] ✅ 根文件系统镜像创建完成"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] 📦 创建 /boot 镜像 (vendor 分区, ext4, ${BOOT_SIZE})"
truncate -s ${BOOT_SIZE} ${BOOT_NAME}
mkfs.ext4 -L boot ${BOOT_NAME}
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] ✅ /boot 镜像创建完成"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] 📦 创建 EFI 镜像 (cust 分区, FAT32, ${EFI_SIZE})"
truncate -s ${EFI_SIZE} ${EFI_NAME}
mkfs.fat -F 32 -S 4096 -s 1 -v -n "efi" ${EFI_NAME}
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [01] ✅ EFI 镜像创建完成"
