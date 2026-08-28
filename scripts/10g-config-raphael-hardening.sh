#!/bin/bash
set -e

# [10g] userspace hardening overlay —— 复刻生产机 2026-08-27 加固差异：
#   1) sim-init 无卡快速跳过 + 单元限流/超时
#   2) hexagonrpcd trigger 重写（als-oem 解耦 + StartLimit）
#   3) 新增 raphael-als-oem.service / raphael-sensors.target
#   4) slpi 三单元 WantedBy 迁到 raphael-sensors.target
#   5) 新增 raphael-glink-watch 看门狗、low-memory-monitor 调度清理、journald 限容
#   6) 背光节点双名（ae94000.dsi.0 / panel0-backlight）修复
# overlay/ 内容整体覆盖 06/10b/10c(deb)/13b 生成的旧版文件（来源明细见 overlay/README.md）。
# 修改前面脚本的 heredoc 或 debs/ 内文件时，请在同一提交里同步 overlay/ 对应副本。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERLAY_DIR="${OVERLAY_DIR:-$SCRIPT_DIR/../overlay}"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10g] 🛡️ 应用 userspace hardening overlay"
if [ ! -d "$OVERLAY_DIR" ]; then
    echo "[10g] ❌ overlay 目录不存在: $OVERLAY_DIR" >&2
    exit 1
fi

# 1) 覆盖写入（cp -a 保留权限与符号链接；构建以 root 运行，但 git 检出文件属主是构建用户，补回 root）
cp -a "$OVERLAY_DIR"/. rootdir/
chown -R 0:0 rootdir/etc/systemd rootdir/etc/udev/rules.d rootdir/usr/libexec rootdir/usr/local/sbin

# 2) 权限兜底（与生产机一致：sbin/libexec 0755，单元/配置 0644）
chmod 0755 \
    rootdir/usr/local/sbin/raphael-sim-init.sh \
    rootdir/usr/local/sbin/raphael-glink-watch.sh \
    rootdir/usr/libexec/raphael-als-oem-init.sh \
    rootdir/usr/libexec/raphael-slpi-bl-notify.py \
    rootdir/usr/libexec/raphael-slpi-client2slpi.sh

# 3) 移除 10c 传感器 deb postinst 生成的 stale 链接（单元已改为 WantedBy=raphael-sensors.target）
rm -f \
    rootdir/etc/systemd/system/multi-user.target.wants/raphael-slpi-bl-notify.service \
    rootdir/etc/systemd/system/multi-user.target.wants/raphael-slpi-client2slpi.service \
    rootdir/etc/systemd/system/multi-user.target.wants/raphael-slpi-oled-gate.service

# 4) 创建 raphael-sensors.target.wants 链接（绝对目标；不依赖 chroot 里 systemctl，同 10c 手法）
mkdir -p rootdir/etc/systemd/system/raphael-sensors.target.wants
ln -sfn /etc/systemd/system/raphael-slpi-bl-notify.service   rootdir/etc/systemd/system/raphael-sensors.target.wants/raphael-slpi-bl-notify.service
ln -sfn /etc/systemd/system/raphael-slpi-client2slpi.service rootdir/etc/systemd/system/raphael-sensors.target.wants/raphael-slpi-client2slpi.service
ln -sfn /etc/systemd/system/raphael-slpi-oled-gate.service   rootdir/etc/systemd/system/raphael-sensors.target.wants/raphael-slpi-oled-gate.service

# 5) 启用 glink 看门狗
mkdir -p rootdir/etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/raphael-glink-watch.service rootdir/etc/systemd/system/multi-user.target.wants/raphael-glink-watch.service

# 6) 校验（仿 10c 的 fail 风格：关键文件非空，链接就位）
fail=0
for f in \
    usr/local/sbin/raphael-sim-init.sh \
    usr/local/sbin/raphael-glink-watch.sh \
    usr/libexec/raphael-als-oem-init.sh \
    usr/libexec/raphael-slpi-bl-notify.py \
    usr/libexec/raphael-slpi-client2slpi.sh \
    etc/systemd/system/raphael-als-oem.service \
    etc/systemd/system/raphael-sensors.target \
    etc/systemd/system/raphael-glink-watch.service \
    etc/systemd/system/raphael-sim-init.service \
    etc/systemd/system/raphael-slpi-bl-notify.service \
    etc/systemd/system/raphael-slpi-client2slpi.service \
    etc/systemd/system/raphael-slpi-oled-gate.service \
    etc/systemd/system/hexagonrpcd-sdsp.service.d/trigger-on-device.conf \
    etc/systemd/system/low-memory-monitor.service.d/override.conf \
    etc/systemd/journald.conf.d/50-size-limit.conf \
    etc/udev/rules.d/98-raphael-backlight-wake.rules \
    etc/udev/rules.d/99-raphael-fastrpc-backlight.rules; do
    [ -s "rootdir/$f" ] || { echo "[10g] ❌ 空或缺失: /$f" >&2; fail=1; }
done
for u in raphael-slpi-bl-notify raphael-slpi-client2slpi raphael-slpi-oled-gate; do
    [ -L "rootdir/etc/systemd/system/raphael-sensors.target.wants/$u.service" ] || { echo "[10g] ❌ 缺少 wants 链接: $u" >&2; fail=1; }
    if [ -e "rootdir/etc/systemd/system/multi-user.target.wants/$u.service" ]; then
        echo "[10g] ❌ stale 链接仍在 multi-user.target.wants: $u" >&2; fail=1
    fi
done
[ -L rootdir/etc/systemd/system/multi-user.target.wants/raphael-glink-watch.service ] || { echo "[10g] ❌ 缺少 glink-watch 链接" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1

# 7) 可选：systemd-analyze verify（chroot 环境可用时；失败不阻断）
if [ -x rootdir/usr/bin/systemd-analyze ]; then
    chroot rootdir systemd-analyze verify \
        /etc/systemd/system/raphael-als-oem.service \
        /etc/systemd/system/raphael-sensors.target \
        /etc/systemd/system/raphael-glink-watch.service \
        /etc/systemd/system/raphael-sim-init.service \
        /etc/systemd/system/raphael-slpi-bl-notify.service \
        /etc/systemd/system/raphael-slpi-client2slpi.service \
        /etc/systemd/system/raphael-slpi-oled-gate.service 2>&1 | grep -v '^$' || true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [10g] ✅ hardening overlay 应用完成"
