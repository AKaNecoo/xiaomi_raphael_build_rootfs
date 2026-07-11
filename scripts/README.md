# rootfs 构建脚本

本目录仅保留 **rootfs 镜像构建** 用的编号脚本（`00-` … `17-`）。

## 传感器 / DIAG（deb 安装，不在此目录）

源码与构建在 **`xiaomi_raphael_build_kernel`**：

| deb 包 | 说明 |
|--------|------|
| `hexagonrpcd_*` | FastRPC + HexagonFS |
| `libssc0_*` | SSC 协议 |
| `iio-sensor-proxy_*` | 桌面传感器 |
| `sensors-xiaomi-raphael_*` | runtime libexec + systemd |
| `sensors-tools-xiaomi-raphael_*` | ALS/TCS 调试工具 |
| `diag-router_*` | DIAG 路由 |
| `diag-xiaomi-raphael_*` | DIAG 抓包脚本 |

构建：

```bash
cd ../xiaomi_raphael_build_kernel
./raphael-sensors_build.sh          # 完整
./raphael-sensors_build.sh runtime  # 仅打包 deb
```

产物：`xiaomi_raphael_build_kernel/output/`

rootfs 构建时 `06`/`10c`/`10d` 从对应目录 `dpkg -i` 安装。

## Modem / QCOM deb

在 **`基带测试/mm/mm`** 编译后复制到 `rootfs/debs/`：

```bash
cd 基带测试/mm/mm
./build.sh && ./make-deb.sh
cp debs/modemmanager-qrtr-sm8150_*_jammy_arm64.deb \
   debs/libqrtr1_* debs/libqrtr-dev_* \
   ../../xiaomi_raphael_build_rootfs/debs/
```

补丁在 `mm/mm/patches/`，不在 rootfs 仓库内。
