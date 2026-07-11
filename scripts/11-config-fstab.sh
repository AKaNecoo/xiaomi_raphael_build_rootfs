#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] 🗂️ 配置 fstab"

echo "PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=vendor /boot ext4 errors=remount-ro 0 2
PARTLABEL=cust /boot/efi vfat umask=0077 0 1
PARTLABEL=persist /persist ext4 nosuid,nodev,noatime 0 1" > rootdir/etc/fstab

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [11] ✅ fstab 配置完成"
