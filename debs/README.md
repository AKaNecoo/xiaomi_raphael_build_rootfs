# rootfs/debs — 刷机用本地 deb（每包一个版本）

## 传感器 / IMU / 环境光（SSC 栈）

| deb | 作用 |
|-----|------|
| `hexagonrpcd_*` | FastRPC → SLPI |
| `libssc0_*` | SSC 客户端（**IMU、光感、距离** 数据通路） |
| `iio-sensor-proxy_*` | 桌面传感器代理（旋转、自动亮度） |
| `sensors-xiaomi-raphael_*` | runtime 脚本 + systemd |
| `sensors-tools-xiaomi-raphael_*` | ALS/TCS 调试工具 |
| `diag-router_*` / `diag-xiaomi-raphael_*` | DIAG 抓包（可选） |

构建后同步：

```bash
cd xiaomi_raphael_build_kernel
./raphael-sensors_build.sh runtime
./scripts/sync-debs-to-rootfs.sh
```

## QCOM / Modem

| deb | 来源 |
|-----|------|
| `libqrtr*`、`qrtr-tools`、`rmtfs`、`pd-mapper`、`tqftpserv` | 预置 |
| `audioreach-topology_*` | 预置 |
| `modemmanager-qrtr-sm8150_*` | `基带测试/mm/mm` 编译 |
