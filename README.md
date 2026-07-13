# 小米 Raphael（Redmi K20 Pro）Linux 系统镜像构建项目

为小米 Raphael（Redmi K20 Pro / SM8150）打造的一套 Linux 镜像构建工具链，提供完整的 Debian / Ubuntu 镜像构建脚本与 GitHub Actions 自动化工作流，产出开箱即用的卡刷包。

---

## 1. 项目目的

把"主线 Linux 跑在 K20 Pro 上"这件事**工程化、可复现**：

- **一键产出可刷机的系统镜像**：内核、设备固件、根文件系统、引导（u-boot）全部打包进一个 Recovery 卡刷包，刷入即用，不需要使用者再手动拼装。
- **固化设备适配与基带修复**：把零散的驱动、固件、内核补丁、开机初始化逻辑全部沉淀到构建脚本里，每次构建都自带这些修复，避免"换台机器/重装就丢"。
- **多系统多内核可选**：Debian / Ubuntu × Server / GNOME / Phosh × 多内核版本，按需构建。
- **本地与云端两种构建方式**：既能 Fork 后用 GitHub Actions 云端构建，也能在本地一条命令构建。

---

## 2. 如何使用产物

### 2.1 设备适配状态

| 硬件 | 说明 | 状态 |
|:---:|:---|:---:|
| 屏幕显示 | 偶发黑白颠倒；熄屏再亮或重启可恢复 |  ✅  |
| 触摸屏 | 需**原装**屏幕 |  ✅  |
| GPU 渲染 | | ✅ |
| Wi-Fi | 2.4G / 5G 双频 |  ✅  |
| 蓝牙 | 文件传输 / 音频输出 |  ✅  |
| 蜂窝 / 基带 | SIM 识别、注册、移动数据（IPv4/IPv6）；**上网须插 SIM2**；电信 / 联通 / 移动可用，广电未测试 |  ✅  |
| USB | SSH / OTG / NCM 网络共享 |  ✅  |
| 音频（扬声器 / 耳机） | 耳机须**慢插**到位才识别；快插可能检测不到 |  ✅  |
| 电池 | 电量检测 |  ✅  |
| 实时时钟 | |  ✅  |
| 手电筒 | 含亮度调节 |  ✅  |
| FDE 加密 | |  ✅  |
| 加速度 / 陀螺仪等 IIO | 依赖 SLPI |  ✅  |
| GPS | ModemManager QMI LOC → `raphael-gpsd-bridge` → gpsd（`/dev/gps0`） |  ✅  |
| IMU / 地磁（xgps） | 同桥接写入 `$OHPR` → 同一 `/dev/gps0`（xgps ATT，单设备） |  ✅  |
| 环境光 |  |  ✅  |
| 近距离 |  |  ✅  |
| Venus 硬件加速 | 正在处理 |  ⏳  |
| NPU | 尚不正常 |  ⏳  |
| 相机 | 无支持计划 |  ❌  |
| 通话 | 无支持计划 |  ❌  |
| 短信 | 无支持计划 |  ❌  |

### 2.2 获取镜像

前往本仓库 [Releases](https://github.com/GavinLiuOnline/xiaomi_raphael_build_rootfs/releases) 下载对应机型的 `.zip` 卡刷包，无需本地编译。卡刷包分区映射如下：

| 卡刷包内文件 | 刷入分区 | 内容 |
|---|---|---|
| `boot.img` | `boot` | U-Boot |
| `vendor.img` | `vendor` | `/boot`（ext4：内核 / initrd / dtbs / `refind_linux.conf`） |
| `firmware-update/cust.img` | `cust` | EFI（FAT：rEFInd，`EFI/BOOT/BOOTAA64.EFI`） |
| `system.img` | `userdata` | 根文件系统 |
| `firmware-update/logo.img` | `logo` | 开机 logo |
| `firmware-update/vbmeta.img` / `dtbo.img` | `vbmeta` / `dtbo` | 校验与 DTBO（脚本会先清零再写入） |

> 内核放在 **vendor**、EFI 放在 **cust**，避免 Recovery 清 cache 丢内核，也与 U-Boot `bootefi` 默认找 `EFI/BOOT/` 的布局一致。  
> 体积超过 GitHub Release 单文件 2GB 限制的镜像（如部分 `ubuntu-gnome` 镜像）会被拆分为 `*.partXX` 分卷，或仅保留在 Actions 的 Artifacts 中。

#### 系统类型对照

| 系统标识 | 桌面环境 | 基础发行版 |
|---|---|---|
| debian-server | 无（纯命令行） | Debian |
| debian-gnome | GNOME | Debian |
| debian-phosh | Phosh 移动端桌面 | Debian |
| ubuntu-server | 无（纯命令行） | Ubuntu |
| ubuntu-gnome | GNOME | Ubuntu |
| ubuntu-phosh | Phosh 移动端桌面 | Ubuntu |

### 2.3 前置准备

1. 设备已完成 **Bootloader 解锁**。
2. 电脑安装好 `adb`、`fastboot`，并配置环境变量。
3. 已刷入第三方 Recovery（TWRP / OrangeFox）——卡刷方式需要。

### 2.4 合并分卷（仅当下载到 `*.partXX` 时）

被拆分的卡刷包必须下载**同一个包的全部分卷**、放在同一目录里合并成完整 `.zip` 后才能刷入：

```bash
# Linux / macOS：按顺序合并所有分卷
cat 文件名.zip.part* > 文件名.zip
# 校验：输出应与 Release 页面给出的 SHA256 一致
sha256sum 文件名.zip
```

```bat
:: Windows (CMD)：按顺序拼接
copy /b 文件名.zip.part00 + 文件名.zip.part01 + 文件名.zip.part02 文件名.zip
```

> 未被拆分的卡刷包跳过此步。合并后 SHA256 对不上 = 分卷不全或下载损坏，请重新下载，**切勿刷入**。

### 2.5 刷机

#### 方式 A：Recovery 卡刷（推荐，使用 Release 的 `.zip`）

进入第三方 Recovery 后，任选一种：

- **A1 — adb sideload（最推荐，不占用手机存储）**

```bash
# 在 Recovery 中进入「高级」→「ADB Sideload」并滑动开始，然后在电脑执行：
adb sideload 文件名.zip
```

- **A2 — Recovery 本地安装**：将完整 `.zip` 拷到**外置 SD 卡**，在 Recovery「安装」中选中该 `.zip` 滑动确认。

> ⚠️ **不要把卡刷包放在「内置存储」里刷入！** 卡刷会写入并格式化 userdata（内置存储），放在内置存储上的包会在刷入过程中被清除而导致失败。请使用 **外置 SD 卡** 存放，或用 **adb sideload**（从电脑传入，不占用内置存储）。

#### 方式 B：fastboot 手动刷入

适用于本地构建产物，或把卡刷包 `.zip` 解压后按同名文件刷入。当前分区结构（与卡刷 `updater-script` 一致）：

| 本地构建产物 | 卡刷包内对应 | 分区 |
|---|---|---|
| `pack/boot.img` | `boot.img` | `boot`（U-Boot） |
| `xiaomi-k20pro-boot.img` | `vendor.img` | `vendor`（`/boot` ext4） |
| `xiaomi-k20pro-efi.img` | `firmware-update/cust.img` | `cust`（EFI FAT / rEFInd） |
| `rootfs.img`（可由 `rootfs.7z` 解出） | `system.img` | `userdata` |
| `pack/firmware-update/logo.img` 等 | 同路径 | `logo` / `vbmeta` / `dtbo` |

```bash
# 1. 进入 Fastboot 模式
adb reboot bootloader

# 2. 擦除（与卡刷脚本一致；会清空 userdata）
fastboot erase dtbo
fastboot erase boot
fastboot erase cache
fastboot erase vendor
fastboot erase userdata
fastboot erase vbmeta
fastboot erase cust

# 3. 刷入引导链与系统（以下为本地构建文件名；若解压卡刷包请换成 zip 内同名）
fastboot flash boot    pack/boot.img
fastboot flash vendor  xiaomi-k20pro-boot.img
fastboot flash cust    xiaomi-k20pro-efi.img
fastboot flash userdata rootfs.img
fastboot flash logo    pack/firmware-update/logo.img
fastboot flash vbmeta  pack/firmware-update/vbmeta.img
fastboot flash dtbo    pack/firmware-update/dtbo.img

# 4. 重启
fastboot reboot
```

> ⚠️ **不要再把内核刷进 `cache`**：旧文档的 `fastboot flash cache …` 已废弃。缺少 `cust`（rEFInd）或 `vendor`（内核/DTB）都会导致无法进系统或 Wi-Fi/音频/基带/传感器连环失效。

### 2.6 首次登录与联网

- **默认账号**：普通用户 `user` / `1234`，超级用户 `root` / `1234`
- **USB 直连 SSH**：设备默认 IP `172.16.42.1`，连接命令 `ssh user@172.16.42.1`
- **Server 版联网**：① OTG 外接网线自动识别；② OTG 外接键盘后终端 `nmtui` 连 Wi-Fi；③ USB 连电脑装 NCM 驱动后用 `nmtui` 配置

#### 使用移动数据

镜像已固化基带修复，插卡即可注册网络。出于功耗与误拨考虑，**移动数据默认不自动连接**，需手动开启：

```bash
# 关闭 Wi-Fi（可选，确保走蜂窝）
sudo nmcli radio wifi off

# 连接移动数据（连接名以运营商为准，可用 nmcli connection show 查看）
sudo nmcli connection up CTNET

# 验证
ping -4 -c 3 www.baidu.com
```

> DNS 已固定使用公共 DNS（`223.5.5.5` / `114.114.114.114`），不跟随运营商下发，连上即可解析域名。如需开机自动联网：`sudo nmcli connection modify <连接名> connection.autoconnect yes`。

### 2.7 镜像通用特性

- 默认配置**清华软件源**，预装简体中文语言包与中国标准时区，开箱汉化
- 内置 SSH 服务，支持 root / 普通用户远程登录；支持 USB NCM 网络共享
- **蜂窝基带开箱可用**：匹配 modem 固件（00161）+ 内核 IPA 数据面修复 + SIM 开机自动初始化 + QRTR 版 ModemManager（QMAPv4）
- **音频**：预装 **`alsa-xiaomi-raphael`**（K20 专属 UCM）；**jammy / bookworm** 默认 **PulseAudio**；**noble+ / trixie+** 默认 **PipeWire + soft-mixer + S16LE**（扬声器可正常音量）。GNOME 带 `raphael-rdp-audio-watch`：RDP 断开后自动拉回 **HiFi → Speaker (TFA9874)**，不会在远程会话进行中乱切/狂重启 WirePlumber
- **浏览器媒体（GNOME）**：预装 ffmpeg / openh264 等，避免「不支持 HTML5 视频」类提示
- **桌面**：GNOME / Phosh；**GNOME 电源键**短按熄/亮屏，长按约 **1s** 弹出关机菜单；服务器版开机约 15 秒自动熄屏，快捷命令 `leijun`（关屏）/ `jinfan`（点亮）
- **GNOME Remote Login（noble+ / trixie+）**：系统级 RDP（默认账号同 `user`/`1234`），首次开机自动启用；依赖 PipeWire，与会话内「桌面共享」不是同一套；客户端请关闭「远程音频」（见注意事项）
- **引导与 DTB**：rEFInd 通过 `dtb=\dtbs\qcom\sm8150-xiaomi-raphael.dtb` 加载 vendor 上固件路径正确的设备树（`.mdt`）；Plymouth 厂商开机动画

---

## 3. 如何下载源码构建 / Fork 构建

### 方式一：Fork + GitHub Actions 云端构建（推荐，无需本地环境）

1. **Fork** 本仓库到个人 GitHub 账号。
2. 进入仓库 **Actions** 页面，选择「构建系统镜像」工作流。
3. 点击 **Run workflow**，按需自定义参数：
   - **构建模式**：`parallel` 并行构建全部（默认）/ `single` 单独构建指定镜像
   - **系统类型**：多类型用逗号分隔，默认全量
   - **内核版本**：`7.0`（默认）/ `6.18`
   - **构建工具**：`mmdebstrap`（默认）/ `debootstrap`
   - **Phosh 变体**：仅 Phosh 镜像生效，`phosh-core`（默认）/ `phosh-full` / `phosh-phone`
   - **系统版本**：Debian 默认 `trixie`，Ubuntu 默认 `resolute`（可选 `noble` / `jammy`）
4. 工作流执行完成后，镜像自动打包发布到你 Fork 仓库的 **Releases**（大文件自动拆分为分卷）。

### 方式二：本地构建

适用于任何架构主机，目标始终为 arm64；x86_64 主机会自动用 `qemu-user-static` 跨架构编译。

```bash
# 1. 克隆源码
git clone https://github.com/GavinLiuOnline/xiaomi_raphael_build_rootfs.git
cd xiaomi_raphael_build_rootfs

# 2a. 交互式选择（推荐，按提示选系统/版本/内核）
sudo ./local-build.sh

# 2b. 或直接传参：<系统类型> [内核版本] [桌面环境]
sudo ./local-build.sh ubuntu-phosh 6.18 phosh-full
sudo ./local-build.sh debian-server 7.0
```

`local-build.sh` 会自动安装依赖（`mmdebstrap`/`debootstrap`、`p7zip`、`zip`、`qemu-user-static` 等）、下载内核包与 `boot.img`，再调用 `build.sh` 完成构建。产物为 `rootfs.img` / `rootfs.7z` 及卡刷包 `.zip`。

> 构建所需的内核 deb（`linux-image` / `linux-headers` / `firmware` / `alsa`）默认从内核仓库 Release 下载；也可手动放到项目根目录后离线构建。

### 内核单独更新（仅调试用，非必要无需更新）

设备上可一键升级定制内核（建议 root）：

```bash
# 官方原始链接
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/Update-kernel.sh)"

# 国内加速链接
sudo bash -c "$(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/GengWei1997/kernel-deb/refs/heads/main/ghproxy-Update-kernel.sh)"
```

执行完成后重启设备即可生效。

---

## 4. 注意事项

- ⚠️ **卡刷包切勿放在内置存储刷入**：刷机会格式化 userdata（内置存储），放在内置存储上的包会被清除导致失败。请用**外置 SD 卡**或 **adb sideload**。
- **分卷必须先合并再刷**：`*.partXX` 要下齐、合并成完整 `.zip` 并核对 SHA256 后才能刷入。
- **刷机有风险**：会擦除 `userdata` / `vendor` / `cust` 等分区，请提前备份；务必确认 Bootloader 已解锁。
- **移动数据默认不自动连接**：需手动 `nmcli connection up <连接名>`，详见 2.5。
- **必须刷齐 boot + vendor + cust + userdata**：缺 `cust` 进不了 rEFInd；缺 `vendor` 或 `refind_linux.conf` 无 `dtb=` 时会沿用 U-Boot 旧 FDT（固件名 `.mbn`），导致 ADSP/modem/SLPI/IPA 起不来，表现为**声音 / Wi-Fi / 基带 / 传感器一起挂**。
- **音频依赖 `alsa-xiaomi-raphael` + 正确音频栈**：jammy/bookworm → PulseAudio；noble+/trixie+ GNOME → **必须 PipeWire**（Remote Login / portal 依赖）。**切勿 purge PipeWire**（会拆 GNOME），也**切勿在 noble GNOME 上改装 PulseAudio 并 mask PipeWire**（RDP 投屏会报 `Couldn't connect pipewire context`）。勿随意 `autoremove`。
- **有线耳机须慢插入**：插到底并稍作停留后再松手，过快插入可能无法识别耳机；拔掉后扬声器应自动切回。
- **RDP 客户端勿开「远程音频」**：客户端若选「在此计算机上播放」，会话内会出现**虚拟输出**（`auto_null`）。请改为**在远程计算机上播放**或**不播放**：
  - Windows 远程桌面：本地资源 → 远程音频 → 设置 → **在远程计算机上播放**（或不要播放）
  - FreeRDP / Remmina：音频模式选 **Local** / 禁用重定向（勿选 Redirect）
  - 断开 RDP 后，`raphael-rdp-audio-watch` 会自动恢复 **HiFi → Speaker (TFA9874)**。若设置里只剩虚拟输出、且没有扬声器/耳机选项，说明 WCD/SlimBus 已挂，**需重启手机**才能恢复（软件切换无效）。
- **Windows 连不上设备 CDC NCM**：参考解决方案视频 [BV1tW4y1A79V](https://www.bilibili.com/video/BV1tW4y1A79V/)。
- 基带固化细节见 `基带测试/RAPHAEL-MODEM-STATUS.md`。

---

## 5. 已知问题

当前镜像上仍未解决（或待验证）的问题：

- **屏幕偶发黑白颠倒**：熄屏后再亮，或重启即可恢复。
- **环境光传感器**：读数 / 自动亮度链路尚不正常。
- **近距离传感器**：尚不正常。
- **Venus 硬件加速**：视频硬解 / 编码尚不正常。
- **NPU**：尚不可用。
- **中国移动蜂窝数据**：可用（firmware 已移除 VoLTE CMCC MCFG，见 build_kernel；手动拨 `cmnet`）；上网须使用 **SIM2**；广电未测试。
- **RF / modem 稳定性**：目前以崩溃隔离避免拖垮整机，根因层面的射频稳定性仍在跟进。

---

## 6. 鸣谢

本项目基于众多开源项目与开发者成果，特此致谢。下列贡献者**不分先后，排名不代表重要性**。

| | | | |
|:---:|:---:|:---:|:---:|
| <a href="https://github.com/GengWei1997"><img src="https://github.com/GengWei1997.png" width="64" height="64" alt="GengWei1997"/></a><br/>[GengWei1997](https://github.com/GengWei1997) | <a href="https://github.com/Pc1598"><img src="https://github.com/Pc1598.png" width="64" height="64" alt="Pc1598"/></a><br/>[Pc1598](https://github.com/Pc1598) | <a href="https://github.com/ccmx200"><img src="https://github.com/ccmx200.png" width="64" height="64" alt="ccmx200"/></a><br/>[ccmx200](https://github.com/ccmx200) | <a href="https://github.com/map220v"><img src="https://github.com/map220v.png" width="64" height="64" alt="map220v"/></a><br/>[map220v](https://github.com/map220v) |

同时感谢：

- Linux 内核官方开发团队、Debian / Ubuntu 开源社区、Phosh 桌面开发团队
- [Aospa-raphael-unofficial/linux](https://github.com/Aospa-raphael-unofficial/linux)、[sm8150-mainline/linux](https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux) 等内核源码支持
- 所有开源贡献者与项目使用者
