#!/bin/bash
set -e

# Raphael IMU/地磁：已并入 10e 的 raphael-gpsd-bridge（单设备 /dev/gps0）。
# 本脚本仅清理早期独立的 raphael-imu-gpsd-bridge / /dev/gps-att0，避免 xgps 双设备切换。

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10f] 🧹 清理独立 IMU gpsd 桥接（已合并进 10e）"

# Remove leftover unit/script if present from older images / partial builds.
rm -f rootdir/usr/local/sbin/raphael-imu-gpsd-bridge
rm -f rootdir/etc/systemd/system/raphael-imu-gpsd-bridge.service
rm -f rootdir/etc/systemd/system/multi-user.target.wants/raphael-imu-gpsd-bridge.service

# Mask so an old enabled unit cannot come back via leftover wants.
mkdir -p rootdir/etc/systemd/system
ln -sfn /dev/null rootdir/etc/systemd/system/raphael-imu-gpsd-bridge.service

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10f] ✅ IMU 已随 /dev/gps0 单设备提供；旧 att 桥接已禁用"
