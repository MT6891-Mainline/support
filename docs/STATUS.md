# chopin (Redmi Note 10 Pro / MT6891) 主线 Linux 移植 —— 当前状态

> 最后更新：2026-10-31
> 镜像：`out-scp-v154-rootfs/boot-stockdt.img`
> 内核：`7.3.0`，分支 `7.3.0-mt6891-xiaomi-chopin`，构建号 `#172`

## 1. 能用什么

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 启动 | ✅ | preloader → LK → GenieZone → Linux，无 U-Boot/UEFI |
| 显示 | ✅ | 厂商 `mediatek_v2` DRM，1080x2400 |
| 触摸 | ✅ | |
| 桌面 | ✅ | Denial (gdm + Wayland)，自动登录 `kily` |
| 硬件渲染 | ✅ | panfrost (Mali-G77)，**810 MHz** |
| 音频 | ✅ | `mt6893mt6359` 声卡 |
| WiFi / 蓝牙 | ✅ | |
| 加速度计 | ✅ | SCP RV33 + 自建 iio-sensor-proxy，自动旋转可用 |
| 自动旋转 | ✅ | |
| **电量显示** | ✅ | BQ27Z561 真库仑计（±1%） |
| **充电** | ✅ | **PD 12V / 3.75A，约 2%/分钟** |
| 熄屏（空闲 60s） | ✅ | 唤醒不花屏 |
| GPU 最高频率 | ✅ | 810 MHz（350→810，**+77%**） |
| 挂起 | ❌ | 见 §4，**永久放弃** |

## 2. 性能实测

### GPU（glmark2-es2-wayland，1080x2400 全屏）

| 频率 | 分数 | 相对 350 |
| --- | --- | --- |
| 350 MHz | 968 | — |
| **810 MHz** | **1710** | **+77%** |

836 MHz 是 SoC 上限，早期测得分 1570，但那组数据用的是"连续扫频"协议
（每次改频后的首轮系统性偏慢），不可靠；810 已经接近饱和，且余量更好。
**推荐 810 MHz**（`/etc/chopin-gpu-freq`，开机由服务应用）。

### 充电

| 项 | 值 |
| --- | --- |
| PD 合约 | 12 V / 2.25 A（DTS 声明 5V/9V/12V） |
| 输入功率 | 23 W |
| 入电池 | 15 W（4.02 V × 3.73 A） |
| 速度 | **2% / 分钟**，19%→100% 约 1 小时 |
| 电池温度 | 40-42 °C（0.17 °C/分钟） |
| 电池信息 | 学习容量 4950 mAh，健康度 99%，循环 3 次 |

## 3. 设备上的关键配置

| 路径 | 作用 |
| --- | --- |
| `/etc/chopin-gpu-freq` | GPU 频率（当前 `810000000`） |
| `/etc/chopin-charge-limit` | 输入限流覆盖（可选） |
| `/etc/chopin-charge-current` | 充电电流覆盖（可选，调低更凉） |
| `chopin-gpu-freq.service` | 开机应用 GPU 频率 |
| `chopin-charge-tune.service` | 开机 + 插拔时应用充电限流 |
| `chopin-no-suspend.desktop` | 会话内挂起抑制锁 |
| `gdm.service.d/10-wait-for-dsi.conf` | 等 DSI 连接后再启动 gdm |

## 4. 已知限制

### 挂起：不可能

三道坎，任何一道都足以阻止：

1. `mtu3` 的 IP sleep 检测依赖没更新的 `softconnect`（**已修**）
2. CMDQ wakelock 在设备挂起阶段被激活 → `Wakeup pending. Abort CPU freeze`
3. 修 2 需要在 DRM 挂起后强制 relax wakelock，可能截断进行中的 CMDQ 事务 → 卡死

实测代价：5 次尝试中 3 次系统卡死、2 次花屏。**熄屏已能满足省电需求**
（面板+显示管线 0.5–1.5 W），挂起再多省 0.3–0.5 W，不值得。

⛔ **禁止**：`echo mem > /sys/power/state`、`rtcwake -m mem -s N`

### 其他

* **无 SoC 温度传感器**（主线缺 thermal 驱动），只能读电池温度
* **充电泵未移植**（33W+ 需要 BQ25970 + 约 2 万行厂商框架）
* 电量计必须用 **100 kHz** I2C（400 kHz 下 i2c0 读全 0xFF）
* 相机、指纹、GNSS 未移植

## 5. 深挖文档

| 文档 | 内容 |
| --- | --- |
| `port/GPU-PERF.md` | GPU 三个缺口的全部实验与结论 |
| `port/CHARGING.md` | 电量计与 PD 快充（含两个上游 bug） |
| `port/SUSPEND-ANALYSIS.md` | 挂起为何不可行 |
| `port/V2-DRM-AUDIT.md` | 厂商 DRM 审计 |
| `port/DRM-CLOCK-GAP.md` | 显示时钟链路 |
| `port/DEBIAN-ROOTFS.md` | rootfs 构建与 Denial 配置 |
| `port/patches/pd-upstream/` | **两个上游补丁**（tcpci_mt6360） |
| `port/GPU-HANDOFF.md` / `port/GPU-PORT.md` | GPU 移交笔记 |

## 6. 最近的关键修复（时间序）

| 提交 | 内容 |
| --- | --- |
| `351d82f70` | MTCMOS provider 扩展到 40 个（修显示时钟） |
| `593a8d3b3` | mmsys 子设备重复绑定 |
| `1a6e01b2a` | v2 DRM ioctl/underrun 加固 |
| `8fa91bb0e` | 挂起时保留 fence 会话 |
| `c8a715ca9` | **panfrost mfg_sel 安全重锁（解锁 810MHz）** |
| `869e32df1`→revert | GPU OPP 表尝试（挂死，已回退） |
| `56ed28e5e` | DSI underrun 恢复改为重试 |
| `0f93fae6a`→revert | DVFSRC 顶档钉住（无收益，已回退） |
| `c92ef7a44` | **DTS 声明 9V/12V PD PDO** |
| `ff801f20a` | tcpci_mt6360 补 POWER_CTRL + LOOK4CONNECTION |
| `ee59e0e0e` | **tcpci_mt6360 unmask alerts（PD 真因）** |

## 7. 镜像清单

| 镜像 | 说明 |
| --- | --- |
| **`out-scp-v154-rootfs`** | ✅ **当前推荐**（PD 快充 + 全部修复） |
| `out-scp-v151-rootfs` | ✅ 真库仑计可用 |
| `out-scp-v143-rootfs` | ✅ 熄屏恢复不放弃 |
| `out-scp-v139-rootfs` | ✅ GPU 810MHz 基线（无后续修复） |
| `out-scp-v130-rootfs` | ✅ 传感器稳定版 |
| `out-scp-v135/136/140/141/142` | ⛔ 挂死或花屏，勿用 |
