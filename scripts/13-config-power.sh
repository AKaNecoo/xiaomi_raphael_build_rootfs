#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13] 🔋 配置电源管理和熄屏"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 禁用睡眠/挂起目标"
chroot rootdir systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# 仅在 Ubuntu 构建时配置 NetworkManager
if [[ "$SYSTEM_TYPE" == *"ubuntu-"* ]]; then 
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13]   └─ 配置 NetworkManager"
    cat > rootdir/etc/netplan/01-network-manager-all.yaml << 'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
fi


# 旧版 tty setterm 熄屏与 Wayland 冲突，会导致黑屏难唤醒；禁用
if [ -f rootdir/etc/systemd/system/blank_screen.service ]; then
	chroot rootdir systemctl disable blank_screen.service 2>/dev/null || true
	rm -f rootdir/etc/systemd/system/multi-user.target.wants/blank_screen.service
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [13] ✅ 电源管理配置完成"
