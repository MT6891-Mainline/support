# chopin-support

Redmi Note 10 Pro（MT6891 / "chopin"）主线 Linux 移植后，**系统跑起来所依赖的
全部非内核文件**：固件、服务、脚本、配置、内核配置、上游补丁。

内核源码不在这里，见同一 workspace 下的 `git/chopin-linux-7.3`
（分支 `7.3.0-mt6891-xiaomi-chopin`）。

## 目录

| 路径 | 内容 |
| --- | --- |
| `firmware/` | `mali_csffw.bin`（panfrost G77）、`mediatek/WIFI_*`（MT7961 WiFi 固件） |
| `rootfs/usr/local/bin/` | 6 个脚本：SCP 启动、IIO trigger、sensorproxy、GPU 频率、充电限流、自动旋转 |
| `rootfs/etc/systemd/system/` | 6 个 unit + `gdm.service.d/10-wait-for-dsi.conf` |
| `rootfs/etc/udev/rules.d/` | 插拔时重新应用充电限流 |
| `rootfs/etc/xdg/autostart/` | 挂起抑制锁 |
| `rootfs/etc/systemd/logind.conf.d/` | logind 不因空闲挂起 |
| `rootfs/etc/dconf/db/local.d/` | GNOME 系统默认（熄屏 60s、禁用锁屏等） |
| `rootfs/etc/chopin-gpu-freq` | GPU 频率（`810000000`） |
| `kernel/chopin_defconfig` | 完整内核 defconfig |
| `kernel/config-7.3-chopin` | 当前 boot 镜像实际使用的 `.config` |
| `tools/` | `build-kernel.sh`、`build-images.sh`（打包 boot 镜像） |
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
| `dconf/00-chopin` | GNOME 系统默认：60 秒熄屏、不锁屏、无 suspend 菜单项 |
| `chopin-growfs.service` | 首次启动自动扩展根文件系统 |
| `mali_csffw.bin` | panfrost 必需，否则 GPU 无法初始化 |
| `mediatek/WIFI_*` | MT7961 WiFi 固件（Debian 包 `firmware-misc-nonfree` 也提供同样的文件） |

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
