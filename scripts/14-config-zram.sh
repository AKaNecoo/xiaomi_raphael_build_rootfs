#!/bin/bash
set -e

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] 🧠 配置 ZRAM Swap"

if [ ! -f rootdir/etc/default/zramswap ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 未找到 /etc/default/zramswap，跳过配置"
    exit 0
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 调整 zramswap 默认参数"
# Default zramswap uses lz4 when ALGO is commented; Raphael kernel only exposes zstd.
grep -q '^ALGO=' rootdir/etc/default/zramswap || echo 'ALGO=zstd' >> rootdir/etc/default/zramswap
grep -q '^SIZE=' rootdir/etc/default/zramswap || echo 'SIZE=4096' >> rootdir/etc/default/zramswap
sed -i \
    -e 's/^#\?ALGO=.*/ALGO=zstd/' \
    -e 's/^#\?SIZE=.*/SIZE=4096/' \
    -e 's/^PERCENT=.*/# &/' \
    rootdir/etc/default/zramswap

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14]   └─ 启用 zramswap 服务"
chroot rootdir systemctl enable zramswap

echo ""
echo "[/etc/default/zramswap]"
cat rootdir/etc/default/zramswap

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [14] ✅ ZRAM 配置完成"
