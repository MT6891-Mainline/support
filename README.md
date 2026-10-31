# chopin-support

Redmi Note 10 Pro（MT6891 / "chopin"）主线 Linux 移植后，**系统跑起来所依赖的
全部非内核文件**：固件、服务、脚本、配置、内核配置、上游补丁。

内核源码不在这里，见同一 workspace 下的 `git/chopin-linux-7.3`
（分支 `7.3.0-mt6891-xiaomi-chopin`）。

## 目录

| 路径 | 内容 |
| --- | --- |
| `firmware/` | `mali_csffw.bin`（panfrost G77）、`mediatek/WIFI_*`（MT7961 WiFi 固件） |
| `dtb/stock-base.dtb` | **厂商 DTB**（201 KB）。boot 镜像必须携带它：LK 会校验，自有 DTB 在 `setup_arch()` 里替换。来源是原机 boot 分区，`n10p/boot_a.img` 是它的最终出处 |
| `rootfs/usr/local/bin/` | 6 个运行时脚本：`chopin-scp-start`、`setup-iio-trigger`、`chopin-sensorproxy`、`chopin-gpu-freq`、`chopin-charge-tune.sh`、`chopin-rotate` |
| `rootfs/etc/systemd/system/` | 6 个 unit + `gdm.service.d/10-wait-for-dsi.conf` |
| `rootfs/etc/udev/rules.d/` | 插拔时重新应用充电限流 |
| `rootfs/etc/xdg/autostart/` | 挂起抑制锁 |
| `rootfs/etc/systemd/logind.conf.d/` | logind 不因空闲挂起 |
| `rootfs/usr/local/bin/chopin-powerkey` | 电源键 → 切换背光（熄屏/亮屏） |
| `rootfs/etc/dconf/db/local.d/` | GNOME 系统默认（熄屏 60s、电源键 no-op、不锁屏） |
| `rootfs/etc/chopin-gpu-freq` | GPU 频率（`810000000`） |
| `kernel/chopin_defconfig` | 完整内核 defconfig |
| `kernel/config-7.3-chopin` | 当前 boot 镜像实际使用的 `.config` |
| `tools/` | `build-kernel.sh`、`build-images.sh`（打包 boot 镜像）、`chopin-provision.sh`、`install-g77-driver.sh`、`fix-wifi-bt.sh` |
| `patches/pd-upstream/` | 2 个上游补丁（tcpci_mt6360 的 PD 修复） |
| `docs/` | 关键设计文档（状态、充电、GPU、挂起、DRM） |

## 安装

```sh
sudo ./install.sh
```

幂等，可以反复执行。会安装固件与配置、启用服务、重载 udev 与 dconf。

## 这些文件解决什么问题

| 文件 | 问题 |
| --- | --- |
| `chopin-scp-start` + `chopin-scp.service` | 启动 SCP RV33，加速度计数据才出来 |
| `setup-iio-trigger` + `chopin-iio-trigger.service` | 给加速度计绑 hrtimer 触发（驱动没有自带） |
| `chopin-sensorproxy` + `.service` | 自建 `net.hadess.SensorProxy`（Debian 的 iio-sensor-proxy 3.7 在此平台上只有 buffer 模式，不可用） |
| `chopin-rotate` | 依赖 sensorproxy 做自动旋转 |
| `chopin-gpu-freq` + `.service` | 通过 mfg_sel 安全重锁把 GPU 拉到 810 MHz（+77%） |
| `chopin-charge-tune.sh` + `.service` + udev | MT6360 默认只给 500 mA；识别 PD/DCP/SDP 后按档设置，PD 下可达 3.75 A |
| `chopin-no-suspend.desktop` + logind conf | 挂起在此平台不可行（见 `docs/SUSPEND-ANALYSIS.md`），用抑制锁挡住 |
| `gdm-wait-for-dsi.conf` | 等 DSI 连接后再启动 gdm，否则"No GPUs found" |
| `dconf/00-chopin` | GNOME 系统默认：60 秒熄屏、不锁屏、电源键交给 chopin-powerkey |
| `chopin-powerkey` | 读 `/dev/input/event0` 的 KEY_POWER，切换背光 |
| `chopin-growfs.service` | 首次启动自动扩展根文件系统 |
| `mali_csffw.bin` | panfrost 必需，否则 GPU 无法初始化 |
| `dtb/stock-base.dtb` | 没有它打不出可启动的镜像（`build-images.sh STOCK_DTB=` 需要） |
| `mediatek/WIFI_*` | MT7961 WiFi 固件（Debian 包 `firmware-misc-nonfree` 也提供同样的文件） |

## 电源键与熄屏

挂起在这个板子上不可用（见 `chopin-docs/power/SUSPEND-ANALYSIS.md` §23），
所以电源键不做挂起，而是**切换背光**：

```
电源键 → chopin-powerkey → /sys/class/backlight/lm36273/brightness
```

* 按一下：保存当前亮度 → 背光设为 0（屏幕黑）
* 再按一下：恢复保存的亮度（瞬时唤醒）

**为什么是背光而不是 DRM 熄屏**：背光切换完全不动 DSI / 面板状态机，零花屏风险；
DRM 熄屏路径正是所有挂起尝试最终把画面搞花的地方。真正的 DPMS 熄屏仍由
60 秒空闲触发（那条路径已验证稳定）。

配套设置（都在 `install.sh` 里）：

| 设置 | 值 | 原因 |
| --- | --- | --- |
| `power-button-action` | `'nothing'` | 否则 gsd 会尝试挂起，被拦后弹关机对话框 |
| `HandlePowerKey` (logind) | `ignore` | 电源键只由 chopin-powerkey 处理 |
| `idle-delay` | 60 s | 自动熄屏 |
| swapfile | 4 GB | 防 gnome-shell 偶发膨胀触发 OOM |

## 不在本仓库里的东西

| 东西 | 在哪 |
| --- | --- |
| SCP 固件 | **由 LK 从 boot 分区加载**（`[SCP] LK region: firmware=9fa02000/143c00`），不在 rootfs |
| 内核源码 / 设备树 | `git/chopin-linux-7.3` |
| boot 镜像 | `out-scp-v154-rootfs/`（18 MB，含 vendor DTB + 内嵌自有 DTB） |
| G77 用户态驱动 | 自建 `libgallium-25.0.7-2+deb13u1.so`，装在 `/usr/lib/aarch64-linux-gnu/`，见 `docs/GPU-PERF.md` |

## 依赖的 Debian 包

```
gnome-core gdm3 python3-gi gir1.2-glib-2.0 libglib2.0-bin
firmware-misc-nonfree   # WiFi 固件（本仓库也带了一份）
i2c-tools               # 调试用
```

## 注意

* GPU 810 MHz 与 PD 快充都是**实测验证过的设置**，不要随手改高：
  836 MHz 无额外收益，充电电流再大会撞温度墙。
* **不要尝试挂起**（`echo mem > /sys/power/state`、`rtcwake -m mem`），
  会把系统卡死。
