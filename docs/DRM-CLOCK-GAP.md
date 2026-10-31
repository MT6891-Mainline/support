# 显示时钟缺口：underflow 与花屏的真正原因（2026-10-28）

一次完整分析，回答「DRM 是不是不完善」。**结论：不是笼统的不完善，
是一个具体的、可定位的时钟 provider 缺口。**

## 1. 症状

* KDE（KWin）跑得好好的；
* GNOME（mutter）一跑就花屏，条纹；
* GDM 首次进入也会花屏；
* 内核日志里一直有：

```
[DISP][E][IRQ] DDP_COMPONENT_OVL0_2L: frame underflow! cnt=0
[DISP][E][IRQ] DDP_COMPONENT_OVL0:  frame underflow! cnt=0
[DISP][E][IRQ] DDP_COMPONENT_RDMA0: abnormal! cnt=0
```

`frame underflow` = 显示控制器从内存取数取不到，屏幕上就是错误像素。
KWin 合成负载低，没越过阈值；mutter 多平面合成一下就越过了。

## 2. 显示栈是谁

```
CONFIG_DRM_MEDIATEK_V2=y        ← 厂商 v2 驱动（不是主线那套）
```

`drivers/gpu/drm/mediatek/Makefile` 里是二选一：

```make
ifeq (y, $(filter y, $(CONFIG_DRM_MEDIATEK_V2)))
obj-$(CONFIG_DRM_MEDIATEK) += mediatek_v2/
obj-$(CONFIG_DRM_MEDIATEK) += mml/
```

所以 `frame underflow` 来自 `mediatek_v2/mtk_disp_rdma.c` 等厂商组件。

## 3. 缺失的那一环：MTCMOS 时钟 provider

显示节点的顶层时钟是这样写的（`mt6893-xiaomi-chopin-display.dtsi`）：

```dts
dispsys_config@14116000 {
        phandle = <0x61>;
        clocks = <&scpsys 20>, <&dispsys_config 54>, <&dispsys_config 20>;
        clock-num = <22>;
};
```

而 `scpsys@10001000` 的时钟 provider 是**我们自己为 GPU 写的最小实现**：

```c
/* drivers/clk/mediatek/clk-mt6893-pg.c */
* Minimal MT6893 MTCMOS clock provider for the MFG (GPU) power islands.
#define MT6893_MTCMOS_NR  9      /* 只有 index 0..8，且只有 MFG 那几个是真的 */
```

于是启动时：

```
of_clk_hw_onecell_get: invalid index 20        ← scpsys 只有 9 个，要 20 号
[DISP][E]mtk_drm_get_top_clk get 0 clk failed  ← 第一个时钟就失败
```

⇒ `mtk_drm_get_top_clk()` 拿不到任何顶层时钟 ⇒ 显示的 DISP/DISP1 PLL mux
没有被程序化，只能靠 bootloader 遗留状态运行 ⇒ **没有任何频率余量**。

再叠加一条：

```
mediatek-drm ...: no display OPP table, mmdvfs voting disabled
```

`mediatek_v2/mtk_disp_pmqos.c:444` 找不到 display OPP 表 ⇒ mmdvfs 无法按负载
升频/升带宽 ⇒ 也没有带宽投票。

120 Hz × 1080 × 2400 × 4 B ≈ 1.25 GB/s 起步，OVL 多层再翻倍。没有余量，
负载一高就 underflow。

## 4. 第二个问题：mmsys 被自己的子设备抢了

```
mtk-mmsys mediatek-drm.7.auto: error -EBUSY: can't request region
                               for resource [mem 0x14116000-0x14116fff]
```

`mtk_mmsys_probe()` 会创建子设备 `mediatek-drm`，而子设备**继承了父设备的
of_node**（为了让 `mtk_drm_probe()` 拿到 match_data）和 memory 资源，于是
platform 总线又拿 `mtk_mmsys_drv` 去匹配这个子设备 → 第二次 ioremap 失败。
这不致命，但会把 mmsys 的 probe 时序搞乱。

## 5. 本次修复（v125）

| 文件 | 改动 |
| --- | --- |
| `drivers/clk/mediatek/clk-mt6893-pg.c` | provider 扩到 `MT6893_MTCMOS_MAX = 40`：MFG 2..8 保持**真实**的 SPM 操作，其余 33 个注册为 **no-op 占位**，让任意 DT 索引都能 `clk_get()` 成功 |
| `drivers/soc/mediatek/mtk-mmsys.c` | `mtk_mmsys_probe()` 里 `if (pdev->id != PLATFORM_DEVID_NONE) return -ENODEV;`，跳过自己创建的子设备 |

占位时钟为什么安全：显示现在**本来就是**在 bootloader 遗留的电源状态下跑，
根本没用过这些时钟；把「失败」换成「空操作」，不会改变实际电源行为，
只是让 `mtk_drm_get_top_clk()` 不再半途退出。

## 6. 验证（下次开机时）

```sh
# 1) 占位时钟注册成功（应看到这一行）
dmesg | grep "MTCMOS clocks"
#   → MTCMOS clocks: 7 real (MFG), 33 placeholders

# 2) 时钟查找不再失败（应无输出）
dmesg | grep -E "invalid index|get .* clk failed"

# 3) EBUSY 消失（应无输出）
dmesg | grep -E "mtk-mmsys.*EBUSY|can't request region"

# 4) underflow 是否归零（关键判据）
dmesg | grep -c underflow          # 跑 KDE 十分钟后看
```

## 7. 如果 underflow 还在

那就是**真带宽不足**（不是时钟解析失败），下一步是：

1. 先用 60 Hz 验证：`kscreen-doctor output.DSI-1.mode.2`（1080x2400@60）
   —— 带宽减半，若 underflow 归零即确认；
2. 给 display 补 `operating-points-v2`，让 `mtk_disp_pmqos` 能投票（治本）；
3. 检查 SMI/LARB 的 QoS 配置是否也需要补。

## 8. 与「GNOME 不兼容」的关系

**不是 GNOME 不兼容**，而是**余量只够 KWin**。修好时钟后余量变大，
mutter 才有可能稳定；但这需要实测确认，不能假设。

即使修好，也建议：先在 60 Hz 下验证 mutter 长时间不花屏，再逐步上 120 Hz。

---

## 9. 面板残影事故（2026-10-28）与恢复流程

### 9.1 经过

1. 装上 GNOME，GDM 启动 → **花屏**（条纹）
2. 随后发现条纹**残留在屏幕上**，切到 OrangeFox 依然可见
3. 关机，荫凉处静置 **20 分钟**
4. 开机 → **屏幕恢复正常**

### 9.2 结论

**面板是 LCD**（chopin = 红米 Note 10 Pro 中国版，6.6" 1080x2400 120 Hz LCD），
不是 AMOLED。所以残留的机理不是「有机发光层衰减」，而是 **液晶图像粘滞
（image sticking / image persistence）**：

* 液晶单元在被持续施加直流偏压时会积累离子电荷，形成与图像一致的
  透光率差异 → 看起来像"烧屏"；
* 一旦停止驱动（关屏/断电），离子会缓慢扩散回去 → **残留自行消退**，
  这正是"关机 20 分钟恢复"的原因；
* 永久性 LCD 灼伤需要**长时间**（几十小时以上）的静止直流驱动，
  短时间花屏几乎不可能造成。

⇒ 风险比 AMOLED 低得多，这也解释了为什么 20 分钟就完全恢复。

判据与处置：

| 现象 | 判断 | 处置 |
| --- | --- | --- |
| 花屏后有条纹残留 | 残影 | **立刻关屏**，静置 20 分钟~几小时 |
| 静置后消失 | 确认是残影 | 正常使用 |
| 静置 12 h 后仍在 | 需继续观察 | 静置数天 + 均匀色循环（全白/黑/RGB/中灰各 10–15 min，中低亮度） |
| 数天后仍在 | 可能永久（LCD 需长期直流偏压才发生，罕见） | 不可逆 |

LCD 的残留主要是**直流偏压导致的离子积累**，所以「停止驱动」比「降温」更关键：
关机（不只是熄屏）> 荫凉 > 时间。不要反复开机查看——每次点亮都是重新施加偏压。

### 9.3 预防规则（重要）

**不要在未验证的渲染路径上用全屏高亮度内容做实验。** 具体到本项目：

| 规则 | 原因 |
| --- | --- |
| 试 mutter / 任何新合成器前，先用 llvmpipe（发行版 Mesa） | 软件渲染最坏只是慢，不会输出错误帧；我们那份 G77 Mesa 是自编实验后端 |
| 新合成器先在 **60 Hz** 下跑 | 带宽减半，underflow 概率大幅下降 |
| 一旦花屏，**立刻**关屏（`echo off > /sys/class/drm/card*-DSI-1/dpms`） | 残留时间与驱动时长正相关 |
| 不要在花屏状态下继续截图/调试 | 每多显示一秒都在加深残留 |

### 9.4 安全推进顺序（面板已恢复，按此执行）

1. 刷 **v125**（时钟修复），**仍用 KDE**（已知不花屏的组合）
2. `dmesg | grep -c underflow` 跑 10 分钟 → **必须为 0** 才继续
3. 用 KDE 在 120 Hz 下长时间使用（滚动、视频）→ 再确认 underflow 为 0
4. 只有第 3 步稳定后，才考虑 mutter：先用 llvmpipe + 60 Hz
5. 最后才把 G77 驱动 + 120 Hz + mutter 三者放到一起

---

## 10. 修复验证（2026-10-30，实测）

### 10.1 修复内容（v125）

```
out-scp-v125-rootfs/boot-stockdt.img   md5 1884aad8fc8309751112a4d4657e3598   18.0 MB
```

| 文件 | 改动 |
| --- | --- |
| `drivers/clk/mediatek/clk-mt6893-pg.c` | provider 从 9 个索引扩到 40：MFG 2..8 保持真实 SPM 操作，其余 33 个为 no-op 占位 |
| `drivers/soc/mediatek/mtk-mmsys.c` | 跳过自己创建的子设备（`pdev->id != PLATFORM_DEVID_NONE`），消除 `-EBUSY` |

### 10.2 验证结果

**① 补丁生效**

```
mt6893-scpsys-clk 10001000.scpsys: MTCMOS clocks: 7 real (MFG), 33 placeholders
```

**② 原来那条致命错误消失**

```
[DISP][E]mtk_drm_get_top_clk get 0 clk failed     ← 修复前每次都有，现在没有
of_clk_hw_onecell_get: invalid index 20           ← 同上，已消失
```

**③ 显示时钟真的有 rate 了（最硬的证据）**

```
$ grep -E "disp_sel|mm_disp_ovl0|mm_disp_rdma0" /sys/kernel/debug/clk/clk_summary
disp_sel          14  14  0  546000000  ...
mm_disp_rdma0      2   2  0  546000000  ...  consumer: disp_rdma@14003000
mm_disp_ovl0_2l    2   2  0  546000000  ...  consumer: disp_ovl@14001000
mm_disp_ovl0       2   2  0  546000000  ...  consumer: disp_ovl@14000000
```

修复前这些是 0 / 无法解析。`disp_sel = 546 MHz` 说明顶层时钟已被程序化并绑定到显示组件。

**④ underflow 归零（核心判据）**

```
$ kscreen-doctor output.DSI-1.mode.1     # 设 1080x2400@120
kscreen.doctor: Taddaaa! Found mode "1" "1080x2400@120"

$ dmesg -C; es2gears_wayland &           # Wayland 原生 GL 负载
284 frames in 5.0 seconds = 56.653 FPS
607 frames in 5.0 seconds = 121.279 FPS   ← 跑满 120Hz vsync
...
$ dmesg | grep -c underflow
0
```

**修复前**同样的负载必然产生 `frame underflow` 并按帧撕裂；**修复后零次**。

**⑤ 渲染路径确认是硬件**

```
$ eglinfo | grep "EGL driver name"
EGL driver name: panfrost
```

### 10.3 结论

`frame underflow` 的根因是**显示顶层时钟从未被程序化**，而这是由
`clk-mt6893-pg.c` 只暴露 index 0..8（为 GPU 写的最小实现）导致显示要的
index 20 解析失败。修复后：

* 显示时钟 546 MHz 正常；
* 120 Hz 下真实 GL 负载零 underflow；
* KDE（KWin）+ G77 Mesa + 120 Hz 是**已验证可用的配置**。

### 10.4 已知稳定配置（回退基准）

| 项 | 值 |
| --- | --- |
| boot 镜像 | `out-scp-v125-rootfs/boot-stockdt.img` |
| 显示管理器 | sddm（**不是** gdm） |
| 桌面 | KDE Plasma（KWin Wayland） |
| Mesa | 自编 G77 `libgallium`（`/usr/lib/aarch64-linux-gnu/`，原文件备份为 `.dist`） |
| 刷新率 | 1080x2400@120 |
| 传感器 | `chopin-scp` + `chopin-iio-trigger` + `chopin-sensorproxy` 三个服务 |
| 判据 | `dmesg \| grep -c underflow` = 0 |

### 10.5 遗留小问题

```
of_clk_hw_onecell_get: invalid index 2
```

开机时出现一次（`dmesg -C` 后抓不到了，需重启复现）。来自某个只注册了
1~2 个时钟的 provider，**与显示无关**（显示要的 20 已正常）。

---

## 11. mutter 嵌套验证通过（2026-10-30）

### 11.1 方法

在 KWin 会话里嵌套跑 GNOME Shell —— **花屏只会发生在窗口内，不会全屏驱动面板**，
是验证 mutter 渲染路径最安全的方式：

```sh
export XDG_RUNTIME_DIR=/run/user/0
export DISPLAY=:0                                    # KWin 的 Xwayland
export XAUTHORITY=$(ls /run/user/0/xauth_* | head -1)
gnome-shell --nested --wayland
```

`--nested` 在 mutter 里是**经 X11 开窗口**的，所以必须给 `DISPLAY` 和
`XAUTHORITY`；只给 `WAYLAND_DISPLAY` 会报
`Failed to setup: Unable to open display, DISPLAY not set`。

### 11.2 结果

```
libmutter-Message: Running GNOME Shell (using mutter 48.7) as a Wayland display server
libmutter-Message: Using public X11 display :1, (using :2 for managed services)
libmutter-WARNING: WL: unable to lock lockfile /run/user/0/wayland-0.lock  ← KWin 占用，自动改用 wayland-1
libmutter-Message: Using Wayland display name 'wayland-1'
GNOME Shell-Message: GNOME Shell started at ...
```

**正常渲染，无花屏。** 其余告警均无害：

| 日志 | 原因 |
| --- | --- |
| `wayland-0.lock` 无法锁 | KWin 已占用 wayland-0，mutter 用 wayland-1 |
| `init_barrier_impl: runtime check failed` | 嵌套模式无 XInput2 barrier |
| `No entry for geolocation` / `GeoClue2` | 未装定位服务 |
| `Failed to start camera monitor` | 无摄像头服务 |
| `Error registering session with GDM` | GDM 未运行，嵌套模式本应如此 |
| `Clutter-CRITICAL ... CLUTTER_IS_ACTOR` | 退出时的收尾告警 |

### 11.3 结论

**mutter 48.7 在这套驱动（panfrost + 自编 G77 Mesa）上可以正常渲染。**
之前那次全屏花屏的根因是 §10 的 `frame underflow`，与 mutter 无关。

### 11.4 切到完整 GNOME 的前置条件

GDM 的 greeter 在这台机器上起不来（`/run/user/108` 无 user manager + X11
greeter 失败），**必须用 autologin 跳过 greeter**：

```sh
printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=root\nWaylandEnable=true\n' \
	> /etc/gdm3/daemon.conf
ln -sf /usr/lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service
systemctl daemon-reload && systemctl reboot
```

一旦花屏：**立刻长按电源关机**，静置 20 分钟（LCD 图像粘滞可恢复，已实测）。

---

## 12. GNOME 首次完整启动（2026-10-30）

### 12.1 GDM 的两个坑

**① GDM 拒绝 root 自动登录**

```
pam_succeed_if(gdm-autologin:auth): requirement "user != root" not met by user "root"
```

GDM 有硬策略，`AutomaticLogin=root` 直接失败。改用普通用户：

```sh
usermod -aG video,render,input,audio,netdev,bluetooth kily
printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=kily\nWaylandEnable=true\n' \
	> /etc/gdm3/daemon.conf
systemctl restart gdm
```

成功标志：

```
gdm-autologin][827]: pam_unix(gdm-autologin:session): session opened for user kily(uid=1000)
/usr/libexec/gdm-wayland-session /usr/bin/gnome-session
gnome-shell[935]: GNOME Shell started at ...
gnome-shell[935]: Registering session with GDM
loginctl: 11 1000 kily seat0 827 user tty2
```

**② `ExecStartPost=systemctl restart ...` 导致开机死锁**

`chopin-iio-trigger.service` 里曾写：

```ini
ExecStartPost=/bin/systemctl restart chopin-sensorproxy
```

oneshot 单元在自己的 ExecStartPost 里重启另一个单元，会和它所在的事务**互相等待**：

```
JOB  UNIT                        STATE
118  chopin-sensorproxy.service    start waiting
2    multi-user.target             start waiting
104  chopin-iio-trigger.service    start running   ← 卡死
```

后果：`multi-user.target` 永不完成、`serial-getty@ttyGS0` 迟迟不起（表现为
"串口连上了但没有登录提示"）。

**修法**：删掉 `ExecStartPost`，改用依赖排序（`chopin-sensorproxy.service` 已有
`After=chopin-iio-trigger.service`，顺序本来就对）：

```sh
sed -i '/ExecStartPost=/d' /etc/systemd/system/chopin-iio-trigger.service
systemctl daemon-reload
```

### 12.2 结果

| 项 | 状态 |
| --- | --- |
| GNOME Shell | 运行中（`gnome-shell` pid 935，session kily @ tty2 / seat0） |
| 会话类型 | Wayland（`gdm-wayland-session`） |
| `disp_sel` | 546 MHz |
| `chopin-scp` / `chopin-iio-trigger` / `chopin-sensorproxy` | 全部 active |
| `serial-getty@ttyGS0` | active（串口登录恢复） |
| `AccelerometerOrientation` | `(<'normal'>,)` |
| `frame underflow` | **2 次，全部在 t=12.7 s**（开机瞬间），GNOME 运行期间 0 次 |

### 12.3 关于开机那 2 次 underflow

```
[12.695710] [DISP][E][IRQ] DDP_COMPONENT_OVL0_2L: frame underflow! cnt=0
[12.695727] [DISP][E][IRQ] DDP_COMPONENT_OVL0:  frame underflow! cnt=0
[12.695772] [DISP][E][IRQ] DDP_COMPONENT_RDMA0: abnormal! cnt=0
```

都在同一时刻、`cnt=0`，且 uptime 4 分钟后仍是 2 次 → 是**显示首次使能时的瞬态**
（时钟/带宽还没稳定），不是持续饥饿。相比修复前"每次高负载必挂"，这是质变。

如果之后长时间使用中计数继续增长，才是真带宽问题，那时再降 60 Hz 或补 OPP 表。

---

## 13. 自动旋转在 GNOME 下原生可用（2026-10-30，最终确认）

### 13.1 证据

`chopin-sensorproxy` 的日志持续输出朝向变化，mutter 随之旋转屏幕：

```
04:52:54 chopin-sensorproxy: orientation bottom-up
04:52:54 chopin-sensorproxy: orientation right-up
04:52:55 chopin-sensorproxy: orientation normal
04:52:58 chopin-sensorproxy: orientation right-up
04:53:02 chopin-sensorproxy: orientation left-up
04:53:24 chopin-sensorproxy: orientation normal
```

用户确认：**倾斜手机，屏幕自动旋转**；GNOME 快捷设置里出现原生「旋转锁定」开关
（GNOME 只有在检测到加速度计时才显示该开关，说明 mutter 已成功消费
`net.hadess.SensorProxy`）。

### 13.2 为什么不用 iio-sensor-proxy

Debian 13 的 `iio-sensor-proxy 3.7` 只支持 IIO buffer 路径，且在本板上无法解析
trigger：

```
Could not find trigger name associated with .../iio:device1
Buffer '/dev/iio:device1' did not have data within 0.5s
```

于是自己实现了同名 D-Bus 接口（`port/rootfs-common/chopin-sensorproxy.py`，
182 行 python3-gi）：直接读 `in_accel_*_raw`，按 180° 矩阵修正后的原始帧判定朝向，
变化时发 `PropertiesChanged`。**对消费者完全等价**——mutter 不知道背后是谁。

### 13.3 最终链路

```
ICM40607 → SCP RV33 固件 FIFO(0x8F0CD000) → 内核 sensorhub（SET_CONFIG 每轮重发）
        → IIO chopin-accel（+ hrtimer trigger，由 chopin-iio-trigger 绑定）
        → chopin-sensorproxy（net.hadess.SensorProxy）
        → mutter orientation → GNOME 自动旋转（带原生开关）
```

### 13.4 最终配置清单

| 项 | 值 |
| --- | --- |
| boot 镜像 | `out-scp-v125-rootfs/boot-stockdt.img`（含时钟修复与 rootfs-only initramfs） |
| rootfs | Debian 13 trixie，1080x2400@120，`/` 已扩到 105 GiB |
| 显示管理器 | **gdm**（`Service=gdm-autologin`，autologin 到 `kily`，跳过 greeter） |
| 桌面 | GNOME 48.7，Wayland 会话 |
| GPU | panfrost + 自编 G77 `libgallium`（系统默认，原文件备份 `.dist`） |
| 显示时钟 | `disp_sel = 546 MHz`，运行期 underflow 0 |
| 传感器服务 | `chopin-scp` / `chopin-iio-trigger` / `chopin-sensorproxy`，全部 enabled+active |
| 自动旋转 | GNOME 原生，状态栏开关可用 |
| 串口 | `serial-getty@ttyGS0` active（`root`/`chopin` 或 `kily`/`123456`） |

### 13.5 尚存的小问题（不阻塞使用）

| 问题 | 说明 |
| --- | --- |
| GDM greeter 起不来 | 缺 `/run/user/108` 的 user manager；已用 autologin 绕过 |
| `of_clk_hw_onecell_get: invalid index 2` | 开机一次，来自某个只注册 1~2 个时钟的 provider，与显示无关 |
| 开机瞬态 2 次 underflow | `t=12.7 s`，`cnt=0`，显示首次使能时的一次性事件 |
| 电量显示 65535% | fuel gauge 驱动未接 |
| conninfra 日志密集 | WiFi 上电/校准，功能正常 |
| `ap0` / `wlan1` / `p2p-dev-*` 多余接口 | 驱动并发模型，可用 NetworkManager `unmanaged-devices` 隐藏 |
| KDE 包仍在 | 可与 GNOME 共存，确认稳定后可 `apt purge` 释放约 1.5 GB |

---

## 14. 花屏的第二种成因：fence session 泄漏（v126 修复）

### 14.1 现象

v125 之后 120Hz 重负载已经不 underflow 了，但**挂起/恢复一次仍然花屏**：

```
[  580.711] [DISP][E]mtk_release_layer_fence:497 layer_info is null   (×24)
```

`underflow` 计数仍是 2（只有开机瞬态）——所以这次**和带宽无关**。

### 14.2 根因：`_mtk_fence_context[]` 只有 3 个槽且永不释放

```c
/* mtk_drm_session.h */
#define MAX_SESSION_COUNT 3                       /* 两个表都只有 3 个 */

/* mtk_fence.c */
struct mtk_fence_session_sync_info _mtk_fence_context[MAX_SESSION_COUNT];
```

* `_get_session_sync_info()` 按 `session_id` 占一个槽，槽满且找不到就返回 `NULL`；
* `mtk_drm_session_destroy()` 只释放 DRM 侧的 `private->session_id[i]`，
  **从不通知 fence 层**——`0xffffffff` 只在 `mtk_fence_init()` 里写过一次；
* 于是每次合成器实例、GDM 重试、挂起/恢复都**永久消耗一个槽**。

三个槽用完以后：

```c
l_info = mtk_fence_get_layer_info(mtk_get_session_id(crtc), tl);
if (!l_info) {
        DDPPR_ERR("layer_info is null\n");
        ret = -EFAULT;      /* 每次提交都失败 */
}
```

合成器永远提交不成功 → 屏幕一直扫描旧 buffer → 花屏，**直到重启**。

### 14.3 修复（v126，两个补丁）

| 文件 | 改动 |
| --- | --- |
| `mediatek_v2/mtk_fence.c` | 表满时**回收槽 0**（`fence table full, evicting slot 0`），不再返回 NULL |
| `mediatek_v2/mtk_drm_crtc.c` | `layer_info` 缺失时**降级返回 `fence_fd = -1`**，不再让整个 commit 失败 |

两个补丁是互补的：前者防止泄漏累积到不可用，后者保证即使再出异常也不会让
整屏花掉。

### 14.4 如何验证

不需要真的挂起（USB gadget 会拒绝休眠），**反复登出/登入**即可消耗 session 槽：

```sh
# 连续终止 GNOME 会话 4 次以上，让 gdm 重新 autologin
for i in 1 2 3 4 5; do
  SID=$(loginctl list-sessions --no-legend | awk '$3==1000 && $6=="seat0"{print $1}' | head -1)
  loginctl terminate-session "$SID"; sleep 20
done
```

判据：

```sh
dmesg | grep -c "layer_info is null"     # 期望 0
dmesg | grep "fence table full" | tail -2 # 期望看到回收日志
```

修复前第 4 次登入后屏幕就会花；修复后应始终正常。

### 14.5 附带发现：mask `sleep.target` 会打挂 GNOME

为了禁挂起执行 `systemctl mask sleep.target suspend.target ...` 之后，
**gnome-session 起来立刻 shutdown**，gdm 循环重试 → **屏幕闪烁**：

```
gdm-autologin: session opened for user kily
gdm-autologin: session closed for user kily
Gdm: GdmDisplay: Session never registered, failing
gnome-session-manager@gnome.service: Stopped
```

**正确做法**是用 logind 配置（不要动 target）：

```ini
# /etc/systemd/logind.conf.d/10-chopin-no-suspend.conf
[Login]
IdleAction=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandlePowerKey=poweroff
```

---

## 15. 固化：`chopin-provision.sh`

所有设备侧改动都收敛到 `port/rootfs-common/chopin-provision.sh`（幂等）：

| 内容 | 落点 |
| --- | --- |
| 三个传感器脚本 | `/usr/local/bin/{chopin-scp-start,setup-iio-trigger,chopin-sensorproxy}` |
| 三个 systemd 单元（**不含 ExecStartPost**） | `/etc/systemd/system/chopin-*.service` |
| 禁用 `iio-sensor-proxy` | — |
| 禁挂起 / 禁空闲黑屏 | `logind.conf.d` + `dconf` 系统默认 |
| GDM autologin（跳过 greeter） | `/etc/gdm3/daemon.conf` + `display-manager.service` |

用 **dconf 系统默认**（`/etc/dconf/db/local.d/` + `/etc/dconf/profile/user`）而不是
`gsettings`，这样设置在任何用户首次登录前就生效，不需要先跑一次会话。

```sh
SESSION_USER=kily sh port/rootfs-common/chopin-provision.sh   # root 执行，可重复跑
```

---

## 16. 重启自动进桌面：实测确认（2026-10-30）

一次真实重启后的状态（uptime 38 s）：

```
会话 1: user=kily seat=seat0 service=gdm-autologin type=wayland
gnome-shell pid=673 运行中
gdm: active，"Session never registered" 计数 = 0   ← 不再循环重试
dmesg: layer_info is null = 0, underflow = 2（开机瞬态）, fence table full = 0
chopin-scp / chopin-iio-trigger / chopin-sensorproxy: 全部 active
```

启动链：

```
graphical.target → display-manager.service → gdm.service
                → gdm-autologin(kily) → GNOME 48.7 Wayland 桌面
```

无人值守、无登录界面。前提就是 §15 的三个检查点：

1. `display-manager.service` → `/usr/lib/systemd/system/gdm.service`
2. `/etc/gdm3/daemon.conf` 里 `AutomaticLogin=kily`（**不能是 root**）
3. **`sleep.target` 没有被 mask**（否则 gnome-session 立刻退出，见 §14.5）

注意：这次验证跑的是 v125 内核；挂起/黑屏后的花屏（§14 的 fence 泄漏）
仍需刷 v126。

---

## 17. 挂起必须被禁止（2026-10-30，实测）

### 17.1 事故链

一次自动挂起把整机搞挂：

```
[67.918] [SMI]common:0 suspend but busy
[68.080] PM: suspend entry (deep)
[68.225] mtu3 11201000.usb: ip sleep failed!!!
[68.225] PM: dpm_run_callback(): platform_pm_suspend returns -16   ← 挂起失败
[68.267] PM: suspend exit
[69.77]  UNBLANK ... DDP_COMPONENT_DSI0: buffer underrun
[97.8]   mediatek-drm: swiotlb buffer is full (sz: 2097152 bytes)   ← 显存池耗尽
```

之后 SSH 拒绝连接、屏幕花屏、只能断电。

**结论：这台机器上挂起不是"还能改进"，而是"绝对不能发生"。**
USB gadget（`ttyGS0` 串口控制台）拒绝休眠，挂起必然失败，而失败的挂起会把显示拆一半
（面板 disable、DSI underrun、`no session for CRTC0`），再 unblank 就花屏，
最后 swiotlb 耗尽锁死图形。

### 17.2 谁发起的挂起

```
05:06:52 systemd-logind: The system will suspend now!
```

是 **logind 自己**。gdm 在老代码下会循环重试登录（会话没注册成功），logind 看到
"没有活跃会话"就按默认 `IdleAction=suspend` + 30s 空闲直接挂起。

### 17.3 修复：用抑制锁，而不是 mask target

**不要 mask `sleep.target`**（会让 gnome-session 立刻 shutdown，见 §14.5）。
正确做法是让会话持有 logind 抑制锁：

```ini
# /etc/xdg/autostart/chopin-no-suspend.desktop
Exec=gnome-session-inhibit --inhibit suspend \
     --reason "suspend is unsupported on chopin" sleep infinity
```

配合 `logind.conf.d` 的 `IdleAction=ignore`。

实测：

```
$ systemctl suspend
Call to Suspend failed: Access denied        ← logind 拒绝
$ dmesg | grep -c "suspend entry"
0                                            ← 从未尝试
会话仍存活，gnome-shell 正常
```

### 17.4 修好 GDM 竞态后，logind 空闲挂起的诱因也消失了

见 §18：GDM 竞态修好后会话能正常注册，logind 不再认为系统空闲。
抑制锁是第二道保险。

---

## 18. GDM 与显示探测的竞态（开机闪屏的第三因）

### 18.1 症状

开机后 gdm 循环，屏幕闪烁，`gnome-shell` 一个都没有：

```
gdm-autologin: session opened for user kily
gdm-autologin: session closed for user kily
Gdm: GdmDisplay: Session never registered, failing
org.gnome.Shell@wayland.service: Failed with result 'protocol'
```

`result 'protocol'` = gnome-shell 没发出 READY 就退出。

### 18.2 直接原因

```
gnome-shell[621]: Failed to open gpu '/dev/dri/card0': No suitable mode setting backend found
gnome-shell[621]: Failed to setup: No GPUs found
```

`card0` 是 **panfrost（纯渲染，无 KMS）**，`card1` 才是 mediatek-drm（有 DSI-1）。
GDM 在显示设备就绪前就启动了会话，mutter 拿不到可用的 KMS 设备。

两张卡其实都在、权限也正常（`kily` 在 `video`/`render` 组，能打开 card1），
纯粹是**时序**问题。

### 18.3 修复：让 GDM 等显示就绪

```ini
# /etc/systemd/system/gdm.service.d/10-wait-for-dsi.conf
[Unit]
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
ExecStartPre=-/bin/sh -c "for i in $(seq 1 100); do if [ -e /sys/class/drm/card1-DSI-1/status ] && [ \"$(cat /sys/class/drm/card1-DSI-1/status 2>/dev/null)\" = connected ]; then exit 0; fi; sleep 0.1; done; exit 0"
```

实测（真实重启后）：

```
gnome-shell pid=729 运行中
会话 1: kily seat0 tty2
gdm "Session never registered" 计数 = 0
layer_info is null = 0，underflow = 2（开机瞬态）
```

### 18.4 三次"开机闪屏"的不同成因（重要，别混淆）

| # | 成因 | 特征 | 修复 |
| --- | --- | --- | --- |
| 1 | mask 了 `sleep.target` | gnome-session 立刻 shutdown，gdm 循环 | 撤销 mask，改用 logind/inhibitor |
| 2 | GDM 与显示探测竞态 | `No GPUs found`，`result 'protocol'` | 加 gdm `ExecStartPre` 等待 DSI connected |
| 3 | logind 空闲挂起（会话没注册时） | `The system will suspend now!` → 挂起失败 → 花屏 | 抑制锁 + IdleAction=ignore |

---

## 19. 音频状态（2026-10-30）

驱动侧无需改动：`CONFIG_SND_SOC_MT6893_MT6359=y` + `CONFIG_SND_SOC_MT6359=y`，
开机即注册 `card 0: mt6893mt6359`、`Playback_1`。

"没有声音"的原因是 **WirePlumber 默认 sink 静音且音量为 0**：

```
* 49. Built-in Audio Stereo   [vol: 0.00 MUTED]
```

`wpctl set-mute @DEFAULT_AUDIO_SINK@ 0` + `wpctl set-volume ... 0.75` 之后正常，
实测 `pw-play` 播放 3 秒 440 Hz 无声压错误。详见 `port/DEBIAN-ROOTFS.md` §6.6c。
