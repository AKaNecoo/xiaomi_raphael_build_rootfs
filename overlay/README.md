# overlay/ — 生产机加固复刻层（2026-08-28）

本目录是 AKaNecoo fork 附加的**用户态加固**：把生产机（2026-08-27 加固后的 K20 Pro Debian 13，
内核 7.0.0-sm8150-gb78acea9a438）上验证过的修复，以文件形式整体覆盖构建脚本 / deb 生成的旧版内容。
`scripts/10g-config-raphael-hardening.sh` 在 10f 之后把它 `cp -a` 进 rootfs，并处理 systemd 启用链接。

## 修了什么（对应生产机实测问题）

| # | 问题（修复前） | 修复 | 关键文件 |
|---|---|---|---|
| 1 | 无 SIM 卡开机 sim-init 重试 15s×1 且 exit 1，拖慢开机；qmicli 挂起无超时，坏启动时把 ModemManager → multi-user → GDM 整条链拖到 4 分钟 | 轮询改 3s、无卡 exit 0 跳过；单元加 TimeoutStartSec=120 + StartLimit 300/5 | `raphael-sim-init.sh`、`raphael-sim-init.service` |
| 2 | hexagonrpcd 启动时内联执行 als-oem-init，SSC 卡死会拖住 sensor 链与开机链 | als-oem-init 移出 ExecStartPost，改 `--no-block` 拉 als-oem/sensors.target/iio-sensor-proxy；StartLimitBurst=6 | `trigger-on-device.conf`、`raphael-als-oem.service`、`raphael-sensors.target` |
| 3 | slpi 三个服务挂 multi-user.target，任一卡住拖慢开机 | WantedBy 迁到 raphael-sensors.target（hexagonrpcd 就绪后按需拉起） | 三个 `raphael-slpi-*.service` |
| 4 | glink 链路卡死时无自愈，DSP 永久假死 | 看门狗：连续 6 次 intent 超时签名 → debugfs crash 触发 SLPI/CDSP/ADSP 恢复（排除 modem） | `raphael-glink-watch.sh` + `.service` |
| 5 | backlight 节点实际名为 `ae94000.dsi.0`（无 panel0-backlight），udev 规则与脚本等旧名全部失效，bl-notify 每 60s 超时重启循环 | 双名探测（真名优先） | udev 98/99 规则、`bl-notify.py`、`client2slpi.sh`、`als-oem-init.sh`、bl-notify 单元 ExecStartPre |
| 6 | low-memory-monitor 因 CPUSchedulingPolicy=fifo + RestrictRealtime 冲突启动失败（SETSCHEDULER） | 清空调度策略回默认 | `low-memory-monitor.service.d/override.conf` |
| 7 | journal 无上限（曾占 4.1G） | SystemMaxUse=100M | `journald.conf.d/50-size-limit.conf` |

修复效果（生产机实测）：坏启动 4:03 → 修复后 1:21 → systemd 加固后 **24.8s** 到桌面；glink 卡死 0 次。

## 文件来源对照（生产机文件 → 仓库原有生成源）

| overlay 路径 | 仓库生成源 | 差异摘要 |
|---|---|---|
| `etc/systemd/system/raphael-sim-init.service` | 10b heredoc | +TimeoutStartSec=120；StartLimitBurst 24→5、移入 [Unit] |
| `usr/local/sbin/raphael-sim-init.sh` | 10b heredoc | 轮询 15s→3s；无卡 exit 0 跳过 provisioning |
| `etc/systemd/system/hexagonrpcd-sdsp.service.d/trigger-on-device.conf` | sensors-xiaomi-raphael 1.4 deb | als-oem 解耦 + --no-block + StartLimit 120/6 |
| `etc/systemd/system/raphael-slpi-bl-notify.service` | sensors-xiaomi-raphael 1.4 deb | ExecStartPre 双名探测；WantedBy→raphael-sensors.target |
| `etc/systemd/system/raphael-slpi-client2slpi.service` | sensors-xiaomi-raphael 1.4 deb | WantedBy→raphael-sensors.target |
| `etc/systemd/system/raphael-slpi-oled-gate.service` | sensors-xiaomi-raphael 1.4 deb | WantedBy→raphael-sensors.target |
| `usr/libexec/raphael-slpi-bl-notify.py` | sensors-xiaomi-raphael 1.4 deb | resolve_backlight_path() 双名探测 |
| `usr/libexec/raphael-slpi-client2slpi.sh` | sensors-xiaomi-raphael 1.4 deb | BL 路径真名优先 |
| `usr/libexec/raphael-als-oem-init.sh` | sensors-xiaomi-raphael 1.4 deb | 双名探测 |
| `etc/udev/rules.d/99-raphael-fastrpc-backlight.rules` | sensors-xiaomi-raphael 1.4 deb | +KERNEL=="ae94000.dsi.0" |
| `etc/udev/rules.d/98-raphael-backlight-wake.rules` | 13b heredoc | +KERNEL=="ae94000.dsi.0"（13b 已同步改） |
| `etc/systemd/system/raphael-als-oem.service` | **新增** | oneshot 解耦单元，由 trigger drop-in 拉起 |
| `etc/systemd/system/raphael-sensors.target` | **新增** | 空 target，聚合 slpi 三服务 |
| `usr/local/sbin/raphael-glink-watch.sh` + `etc/systemd/system/raphael-glink-watch.service` | **新增** | glink 看门狗，multi-user.target.wants 启用 |
| `etc/systemd/system/low-memory-monitor.service.d/override.conf` | **新增** | 清空 CPUSchedulingPolicy |
| `etc/systemd/journald.conf.d/50-size-limit.conf` | **新增** | SystemMaxUse=100M |

## 维护规则

1. **同步更新**：改动 06/10b/13b 的 heredoc 或 debs/ 里传感器包内容时，同一提交里同步 overlay 对应副本，否则 overlay 会把新改动盖回去（或反之）。
2. **背光节点真名**：`ae94000.dsi.0`（DRM 面板驱动注册名）；`panel0-backlight` 不存在，仅作兜底。
3. **deb 升级会回退**：sensors-xiaomi-raphael 升级时会把 overlay 覆盖过的 deb 文件还原为旧版——本项目是 rebuild-and-reflash 模型（debs/ 版本固定），如需保留加固请同步升级 overlay。
4. **诊断脚本**：sensors-tools 的诊断脚本仍写旧名 panel0-backlight（不影响运行中的服务），未纳入 overlay。
