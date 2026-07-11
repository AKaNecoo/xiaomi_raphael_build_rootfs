#!/bin/bash
set -e

IMAGE_NAME="${IMAGE_NAME:-rootfs.img}"
BOOT_IMG="${BOOT_IMG:-xiaomi-k20pro-boot.img}"
EFI_IMG="${EFI_IMG:-xiaomi-k20pro-efi.img}"
IMAGE_UUID="${IMAGE_UUID:-ee8d3593-59b1-480e-a3b6-4fefb17ee7d8}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16] 📦 卸载并完成镜像"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 卸载挂载点..."
umount rootdir/sys 2>/dev/null || true
umount rootdir/proc 2>/dev/null || true
umount rootdir/dev/pts 2>/dev/null || true
umount rootdir/dev 2>/dev/null || true
umount rootdir/boot 2>/dev/null || true
umount efidir 2>/dev/null || true
umount rootdir 2>/dev/null || true

rm -d rootdir 2>/dev/null || true
rmdir efidir 2>/dev/null || true

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 设置根文件系统 UUID: ${IMAGE_UUID}"
e2fsck -f -y ${IMAGE_NAME}
tune2fs -U ${IMAGE_UUID} ${IMAGE_NAME}

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 完成 /boot 镜像 (vendor, ext4)"
e2fsck -f -y ${BOOT_IMG}

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 完成 EFI 镜像 (cust, FAT)"
# FAT 镜像无需 tune2fs; fsck.vfat 可选，此处仅确保已卸载

echo ""
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16]   └─ 分区映射: vendor=/boot(ext4), cust=/efi(FAT), userdata=/"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [16] ✅ 镜像完成"
