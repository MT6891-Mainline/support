# Debian 13 rootfs 制作与启动 — 2026-10-28

本文记录 chopin（Redmi Note 10 Pro / MT6893）上 Debian 13 (trixie) rootfs
的完整制作、刷写与首次开机流程。**已实测跑通**，末尾附实测证据。

---

## 1. 架构：两件东西，互不干扰

```
┌─ boot_a (128 MB) ─────────────────────┐
│  boot-stockdt.img  18 MB              │  厂商 DTB（LK 要套 dtbo overlay）+ 内核 + 极简 initramfs
│   └ 只做一件事：挂 userdata、switch_root │
└───────────────────────────────────────┘
┌─ userdata /dev/sdc75 (107 GB) ────────┐
│  rootfs.img  3 GB ext4 (标签 chopinroot)│  Debian 13，首次开机自动扩到满盘
└───────────────────────────────────────┘
```

两个要点：

1. **boot.img 里必须放厂商 DTB**。LK 要把 `dtbo` 分区的覆盖层套在它上面，
   缺基树的 60 个符号就直接 `ufdt_apply_overlay() failed`，内核根本不会启动。
   我们自己的 DTB 是 `.incbin` 进内核、在 `setup_arch()` 里换掉的。
2. **initramfs 里不能有 Alpine**。`INITRAMFS_MODE=rootfs` 只产出
   356 KB 的 cpio（静态 init + 板级固件），没有 shell、没有 busybox。

---

## 2. 构建 rootfs

```sh
PROFILE=base SIZE=3G \
GPU_DRIVER=$PWD/work/mesa-build/build-cross-x11/src/gallium/targets/dri/libgallium-25.0.7-2+deb13u1.so \
OUT=$PWD/work/debian-base \
port/tools/build-debian.sh
```

产出 `work/debian-base/rootfs.img`（ext4，名义 3 GB，实占约 793 MB）。

### 为什么用 docker 而不是 debootstrap

| 方案 | 结果 |
| --- | --- |
| `debootstrap --foreign` + proot | 卡在 `base-files` 安装，130 包后 `EXIT=1` |
| **docker `--platform linux/arm64`** | **可用**，原生 root 环境 |

关键约束：**装包和打镜像必须在容器内以 root 完成**。宿主机没有 root，
解 docker-export 出来的 tar 会把 `/etc/shadow`、`/usr/bin/sudo` 的属主
变成调用者 uid，systemd 会拒绝启动。镜像是用 `mke2fs -d` 从目录直接生成的，
不需要 loop mount。

### PROFILE

| PROFILE | 内容 |
| --- | --- |
| `base`（默认） | systemd、udev、dbus、NetworkManager + wpa_supplicant、bluez、Mesa、`firmware-mediatek`、openssh、sudo、apt |
| `kde` | base + `kde-plasma-desktop`、`plasma-workspace`、`kwin-wayland`、`sddm`、`konsole`、`dolphin` |

`kde` 在 qemu 模拟下要一两个小时（800+ 包），所以**默认只做 base，桌面到设备上装**。

### 镜像里预置的东西

| 项 | 位置 / 机制 |
| --- | --- |
| G77 版 Mesa 驱动 | `/root/libgallium-25.0.7-2+deb13u1.so`（92 MB），init 从 cpio 取出 |
| 首次开机自动扩盘 | `/etc/systemd/system/chopin-growfs.service` + 标记 `/etc/chopin/grow-rootfs` |
| root 密码 | `chopin`（`chpasswd`） |
| ssh | 已启用，且把 `PermitRootLogin yes` 写进 `sshd_config` |
| 控制台 | `serial-getty@ttyGS0` + `serial-getty@ttyS0` |

### 自动扩盘

```ini
[Service]
Type=oneshot
ExecStart=/usr/lib/systemd/systemd-growfs /
ExecStartPost=/bin/rm -f /etc/chopin/grow-rootfs
```

ext4 支持在线扩容，所以根分区挂着也能扩。跑完删标记 → 只执行一次。
实测：首启后 `Disk (/): 770 MiB / 105.55 GiB`。

---

## 3. 构建 boot 镜像

```sh
INITRAMFS_MODE=rootfs \
KERNEL=$PWD/build/chopin-7.3/arch/arm64/boot/Image \
DTB=$PWD/build/chopin-7.3/arch/arm64/boot/dts/mediatek/mt6893-xiaomi-chopin.dtb \
STOCK_DTB=$PWD/port/out/stock-base.dtb \
port/tools/build-images.sh out-scp-v123-rootfs
```

产出 `out-scp-v123-rootfs/boot-stockdt.img`（18 MB）。

⚠️ **改任何 DT 属性必须用 `port/tools/build-kernel.sh`**，不要直接 `make Image`：
`chopin-board.dtb` 在 Makefile 里没有从 `.dts` 重建的规则，直接编会让 DT 改动
静默失效（踩过两次）。`build-kernel.sh` 会把 FDT 从 Image 里抽出来反编译自检。

---

## 4. 极简 init 做了什么

`port/initramfs-rootfs/init.c`（静态，707 KB）：

| 步骤 | 说明 |
| --- | --- |
| `mount_pseudo()` | proc / sys / devtmpfs / devpts / tmp / run |
| 等 `/dev/sdc75` 出现 | 最多 10 s |
| `mount(ext4, ro)` → 校验 → `remount rw` | 只读探测，防止误伤非 ext4 的分区 |
| `fwload_nvdata()` | 挂 `/dev/sdc6`，取 `WIFI`（NVRAM 校准）和 `BT_Addr` |
| `fwload_vendor()` | `losetup` 挂 vendor（`super` 扇区 13246464）→ 拷整个 `firmware/` |
| `install_firmware()` | 拷 `mali_csffw.bin` |
| `install_gpu_driver()` | 把 cpio 里的 `*.so` 放进新根 `/root` |
| `copy_tree("/lib/modules")` | 跨 switch_root 用 bind mount 会重启，改成拷贝 |
| `mount("."), chroot, exec /sbin/init` | 标准 switch_root |

### 固件为什么必须在这里拷

两个驱动都是 probe 时按名字请求固件，请求不到就放弃：

```
wlan: Direct firmware load for soc3_0_ram_wmmcu_1a_1_hdr.bin failed with error -2
      → WiFi on/off op fail → giving up after 4 retries
Direct firmware load for mediatek/mt6893/BT_Addr failed with error -2
      → giving up loading BT_Addr after 481 retries
```

而这些文件既不在 Debian 的 `firmware-mediatek` 里，也不在 rootfs 里——它们在
Android 分区：

| 文件 | 分区 | 取法 |
| --- | --- | --- |
| `soc3_0_ram_*`、`wifi.cfg`、`bt.cfg`、ROM patch | `vendor`（`super` 内的逻辑分区） | `losetup -o $((13246464*512))` 后 mount |
| `WIFI`（NVRAM）、`BT_Addr` | `nvdata`（`/dev/sdc6`） | 直接挂载；`BT_Addr` 要**字节反转** |

`BT_Addr` 反转是必须的：stock NV 项存显示顺序 `04:e5:98:..`，驱动按小端
bdaddr 消费。

---

## 5. 刷写

```sh
fastboot flash userdata work/debian-base/rootfs.img        # 3 GB
fastboot flash boot_a  out-scp-v123-rootfs/boot-stockdt.img # 18 MB
fastboot reboot
```

串口（`ttyACM0`）应看到：

```
chopin-init: boot partition /dev/sdc75
chopin-init: bootfs sdc75
chopin-init: vendor firmware copied from /dev/sdc61
chopin-init: BT_Addr 04:e5:98:..
chopin-init: installed mali_csffw.bin
chopin-init: installed libgallium-25.0.7-2+deb13u1.so
chopin-init: exec /sbin/init
```

然后 `ttyGS0` getty，`root` / `chopin` 登录。

**回滚**：`out-scp-v121-alpine/boot-stockdt.img`（54.5 MB，带 Alpine 全套工具和
shell）—— rootfs 出问题时刷回去就能进 shell 排查。

---

## 6. 首次开机后要做的四件事

按顺序做，前两件不做就没有传感器 / 没有硬件渲染。

### 6.1 ⚠️ 启动 SCP 核（否则没有传感器）

**这是最容易漏的一环。** SCP 那个 RISC-V 核**不是内核自动启动的**：
`scp-chopin` 把启动序列挂在 debugfs 上，交给用户态完成。Alpine 镜像靠
`/etc/local.d/10-chsensor.start` 做这件事，Debian 里没有任何东西做 →
现象是：

```
$ cat /sys/class/misc/scp/scp_A_status
SCP A is not ready
$ cat /sys/bus/iio/devices/iio:device1/in_accel_x_raw
cat: ...: Resource temporarily unavailable      # 永远 -EAGAIN
$ dmesg | grep chsensor
ipi_comm chsensor: SCP not ready, bring-up deferred   # 每 2 s 一次
```

而 IIO 设备本身是存在的（`chopin-accel`、`in_accel_mount_matrix` 都能读），
所以很容易误判成"驱动坏了"。

#### 手动启动（验证用）

```sh
mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo 2 > /sys/kernel/debug/scp-chopin/patchscp   # group0 base + group1 power gate
echo 1 > /sys/kernel/debug/scp-chopin/fullreset
echo 1 > /sys/kernel/debug/scp-chopin/sram
sleep 1
echo 1 > /sys/kernel/debug/scp-chopin/start
sleep 0.4
echo 1 > /sys/kernel/debug/chsensor/retry
```

成功的日志：

```
SCP A is ready
started: c0 st=00000000 pc=0000034c | c1 st=00000000 pc=00000000
SET_CONFIG fifo 0x8f0cd000 size 1038048 ret 0 (pkt_id 3, pass 1)
SET_CONFIG fifo 0x8f0cd000 size 1038048 ret 0 (pkt_id 3, pass 2)
$ cat .../in_accel_x_raw
852
```

`pc=0000034c` 是好状态。SET_CONFIG 由驱动在 SCP ready 后**自动重发**
（每轮 pass 都发），所以不需要每次手工 retry。

#### 做成开机自启

```sh
# /usr/local/bin/chopin-scp-start  （port/rootfs-common/chopin-scp-start.sh）
systemctl enable chopin-scp.service
```

`chopin-scp.service`（`port/rootfs-common/chopin-scp.service`）在
`local-fs.target` 之后、`display-manager` 之前跑一次。

#### 完整的启动链

| # | 谁 | 做什么 |
| --- | --- | --- |
| 1 | initramfs | 挂 rootfs、拷 vendor/nvdata 固件、放 G77 驱动、switch_root |
| 2 | **`chopin-scp.service`** | **启动 SCP 核** + 0.4 s 后早期 retry |
| 3 | 驱动自动 | SCP ready → 自动发 SET_CONFIG（每轮重发） |
| 4 | IIO | `in_accel_*_raw` 开始出数 |
| 5 | `chopin-rotate`（KDE autostart） | 读姿态 → `kscreen-doctor` 转屏 |

---

### 6.1b ⚠️ 面板残影与「不要用未验证渲染路径做实验」

2026-10-28 的教训：装上 GNOME（mutter）后屏幕花屏，条纹残留到其它系统里也可见，
关机静置 **20 分钟**后恢复。面板是 **LCD**（chopin 中国版 6.6" 120 Hz），
机理是液晶的图像粘滞（直流偏压下的离子积累），停止驱动后自行扩散恢复 ——
不是永久损伤，也不是 AMOLED 的有机层衰减。

规则：

* 试新合成器前**先用 llvmpipe**（发行版 Mesa），软件渲染最坏只是慢；
* 新合成器先跑 **60 Hz**，再上 120 Hz；
* 一花屏立刻关屏：`for d in /sys/class/drm/card*-DSI-1/dpms; do echo off > $d; done`
* 原因见 `port/DRM-CLOCK-GAP.md`：显示顶层时钟没配好，余量只够 KWin。

### 6.2 把 G77 驱动装成系统默认

init 只把驱动放在 `/root`，需要 `LD_LIBRARY_PATH=/root` 才生效。要全局生效：

```sh
sh install-g77-driver.sh          # port/rootfs-common/install-g77-driver.sh
```

它做三件事：备份系统原文件为 `*.dist`、用系统原来的文件名替换、`ldconfig`。
**必须同名**，因为 `libEGL`/`libgbm` 是按名字 `dlopen` 的。

```sh
apt-mark hold libgl1-mesa-dri mesa-libgallium   # 否则 upgrade 会装回软件渲染版
```

`ldconfig` 会警告 `libgallium-*.so is not a symbolic link` —— 无害，Debian 的这个
文件本来就是普通文件。

### 6.3 启动桌面（GNOME，最终采用）

**最终用的是 GNOME，不是 KDE。** 关键步骤与坑：

```sh
# GDM 不允许 root 自动登录（pam_succeed_if: user != root），必须用普通用户
usermod -aG video,render,input,audio,netdev,bluetooth kily
printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=kily\nWaylandEnable=true\n' \
        > /etc/gdm3/daemon.conf
ln -sf /usr/lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service
systemctl daemon-reload && systemctl reboot
```

验证：

```sh
loginctl list-sessions            # 期望 Service=gdm-autologin, Type=wayland, Seat=seat0
pgrep -af gnome-shell
```

`gnome-shell` 的父进程是**用户级 systemd**，不是 gdm 本身——这是 systemd 系统的正常
形态，不代表"不是 gdm 拉起的"。

自动旋转：GNOME 通过 `net.hadess.SensorProxy` 读朝向，本板由
`chopin-sensorproxy` 提供（`iio-sensor-proxy 3.7` 在本板不可用），
倾斜手机即自动旋转，快捷设置里有原生开关。

详见 `port/DRM-CLOCK-GAP.md` §13。

### 6.3a ⚠️ autologin "失效"的一个坑：AccountsService 记录了 X 会话

症状：某次之后**每次开机都进不了桌面**，gdm 日志是：

```
gdm-autologin: session opened for user kily
gdm-autologin: session closed for user kily
Gdm: GdmDisplay: Session never registered, failing
```

而且 `journalctl -b _COMM=gnome-shell` **完全没有输出**（shell 从未启动）。

根因：`/var/lib/AccountsService/users/<user>` 里的 `Session=` 被记成了
`gnome-xorg`，GDM 因此去启动 **X 会话**，而本板 Xorg 起不来
（`Cannot run in framebuffer mode`）→ 会话立刻退出。

`Session=gnome-xorg` 很容易被写进去，例如在本机跑
`gnome-shell --nested --wayland` 时设置了 `DISPLAY=:0`——AccountsService
会把这个 X 会话记成用户的默认会话，之后每次开机都走错。

修复：

```sh
# 1) 记录改回 Wayland 会话
sed 's/^Session=.*/Session=gnome/' \
    /var/lib/AccountsService/users/kily > /tmp/a && cat /tmp/a > /var/lib/AccountsService/users/kily
# 2) 彻底拿走 X 会话，避免再被选中（Xorg 在本板本来就起不来）
mkdir -p /usr/local/share/xsessions-disabled
mv /usr/share/xsessions/gnome-xorg.desktop /usr/local/share/xsessions-disabled/
```

两条都已加进 `chopin-provision.sh`。

**教训**：在这台机器上做 GNOME 相关实验时不要设 `DISPLAY`，
否则 AccountsService 会把 X 会话记成默认，影响后续所有开机。

### 6.3b 备选：KDE Plasma（必须走 autologin）

装完 `kde-plasma-desktop` 后 **SDDM 会卡在欢迎界面**：

```
Running: /usr/bin/X -nolisten tcp ... -displayfd 16
Failed to read display number from pipe
Attempt 1 starting the Display server on vt 2 failed
```

原因：SDDM 默认用 **X11 greeter**，而这块板子上 X 起不来（装了 `xserver-xorg`
也一样）。会话文件本身没问题：

```
/usr/share/wayland-sessions/plasma.desktop     ← Wayland 会话
/usr/share/xsessions/plasmax11.desktop
```

**解法：自动登录，跳过 greeter。**

```sh
mkdir -p /etc/sddm.conf.d
printf '[Autologin]\nUser=root\nSession=plasma.desktop\nRelogin=false\n' \
	> /etc/sddm.conf.d/autologin.conf
systemctl restart sddm
```

自动登录不经过 greeter，直接拉起 `plasma.desktop`，因此不需要 X，也不需要
Wayland greeter。实测 **进桌面成功**。

对手机来说这本来也是最合适的形态——没有键盘，不需要登录界面。

> 注意：**不能**用 `startplasma-wayland` 直接在控制台启动来代替。那样会失败：
> ```
> /usr/bin/xrdb: Can't open display ''
> xcb_connect() failed
> startplasma-wayland: Shutting down...
> ```
> 因为它需要 SDDM/logind 提供的会话环境（`XDG_RUNTIME_DIR`、seat、
> `QT_QPA_PLATFORM`）。必须走 SDDM autologin。

locale 提示（`Detected locale "C" ... switched to "C.UTF-8"`）不影响运行，
想消掉就 `printf 'LANG=C.UTF-8\n' > /etc/locale.conf`。

---

### 6.4 隐藏 AP / P2P 接口（可选）

驱动在 probe 时就建好了 STA + AP + P2P 三套 netdev（Android 并发模型）：

| 接口 | 来源 | 用途 |
| --- | --- | --- |
| `wlan0` / `wlan1` | `NIC_INF_NAME "wlan%d"` | STA，客户端 |
| `ap0` | `gl_p2p_init.c` `AP_INF_NAME "ap%d"` | AP，手机当热点（默认 down、空转） |
| `p2p-dev-*` | cfg80211 | WiFi Direct / 投屏 |

不想要就交给 NetworkManager 别管它们：

```sh
cat > /etc/NetworkManager/conf.d/99-chopin.conf <<'X'
[keyfile]
unmanaged-devices=interface-name:ap0;interface-name:p2p-dev-ap0;interface-name:p2p-dev-wlan0;interface-name:p2p-dev-wlan1
X
systemctl reload NetworkManager
```

驱动层只能改 ifname（`module_param_named(ap, gprifnameap, ...)`），**不能取消创建**；
真要删得改 `gl_p2p_init.c` 并重刷 boot，不划算。

---

## 6.6 一键固化：`chopin-provision.sh`

设备侧的所有配置（传感器服务、禁挂起、GDM autologin、显示管理器）都在
`port/rootfs-common/chopin-provision.sh` 里，幂等，可在 chroot 里或设备上执行：

```sh
SESSION_USER=kily sh port/rootfs-common/chopin-provision.sh
```

**三个必须记住的坑：**

1. **不要 `systemctl mask sleep.target`** —— 会让 `gnome-session` 立刻 shutdown，
   gdm 循环重试造成**屏幕闪烁**，且不进桌面。用
   `/etc/systemd/logind.conf.d/10-chopin-no-suspend.conf` 的 `IdleAction=ignore`。
2. **不要在 oneshot 单元的 `ExecStartPost` 里 `systemctl restart` 别的单元** ——
   会和当前事务死锁，`multi-user.target` 永远不完成，串口 getty 起不来。
3. **必须禁止挂起**，而且不能用 mask target 的方式 —— USB gadget（串口控制台）
   拒绝休眠，挂起必然失败并把显示拆一半，最后 swiotlb 耗尽锁死图形。用
   `/etc/xdg/autostart/chopin-no-suspend.desktop` 里的 `gnome-session-inhibit`
   持有 logind 抑制锁。另外 GDM 要等 `/sys/class/drm/card1-DSI-1/status` 为
   `connected` 再启动，否则 mutter 报 "No GPUs found"，gdm 循环导致闪屏。

详见 `port/DRM-CLOCK-GAP.md` §14/§15。

## 7. 实测结果

```
OS: Debian GNU/Linux 13 (trixie) aarch64
Host: MT6891Z/CZA
Kernel: 7.3.0-g351d82f70495
Display (DSI-1): 1080x2400 @ 120 Hz in 7"
CPU: MT6893 (8)
GPU: Mesa Mali-G77 (Panfrost)          ← G77 驱动生效
Memory: 305.87 MiB / 6.34 GiB (5%)
Disk (/): 770.83 MiB / 105.55 GiB (1%) ← growfs 生效
Local IP (wlan0): 10.22.88.115/24      ← WiFi 生效
```

逐项证据：

| 能力 | 证据 |
| --- | --- |
| 显示 | `mediatek-drm ... fb0: mediatekdrmfb`，DSI-1 1080x2400@120Hz |
| 触摸 | `[NVT-ts-spi] nvt_ts_work_func ... finger leave`（`CONFIG_TOUCHSCREEN_NT36xxx_HOSTDL_SPI=y` + DTS `novatek,invert-y`） |
| GPU 内核 | `panfrost: mali-g77 id 0x9080 shader_present=0x660067`，`renderD128` |
| GPU 用户态 | `eglinfo` → `EGL driver name: panfrost`（替换前是 `kms_swrast`） |
| WiFi | `wlan0` 拿到 `10.22.88.115/24`，`nmcli device` 正常 |
| 蓝牙 | `bluetooth.service` active，`BT_Addr` 已从 nvdata 提取 |
| 扩盘 | `/` 从 3 GB 扩到 105.55 GiB |

---

## 8. 已知问题（不影响上面这些）

| 问题 | 说明 |
| --- | --- |
| `Battery: 65535%` | 电量计返回 `0xFFFF` 哨兵值，fuel gauge 驱动没接上 |
| `Terminal: vt220` | 只是 `TERM` 变量，`export TERM=linux` 即可 |
| `refcount_t: addition on 0` @ `lcm_probe` | `mi-dsi-panel` 的 refcount UAF，每 boot 3 条警告，偶发白屏；与传感器/GPU 无关 |
| conninfra 刷屏 | WiFi 上电/校准日志很密；功能正常 |
| `mtk-mmsys ... -EBUSY` | 重复 ioremap，drm 最终仍成功绑定 |

---

## 9. 文件清单

### 构建脚本

| 文件 | 用途 |
| --- | --- |
| `port/tools/build-debian.sh` | 构建 Debian rootfs（docker arm64；`PROFILE=base\|kde`） |
| `port/tools/build-kernel.sh` | **改 DT 后必用**，保证内嵌 DTB 真的更新 |
| `port/tools/build-images.sh` | 打包 boot 镜像（配合 `INITRAMFS_MODE=rootfs`） |
| `port/tools/mkinitramfs.sh` | 生成 initramfs（`INITRAMFS_MODE=bringup\|rootfs`） |

### 板级脚本

| 文件 | 用途 |
| --- | --- |
| `port/initramfs-rootfs/init.c` | 极简 PID 1：固件提取 + switch_root |
| `port/rootfs-common/chopin-growfs.service` | 首启扩盘 unit |
| `port/rootfs-common/install-g77-driver.sh` | 把 G77 Mesa 装成系统默认 |
| `port/rootfs-common/fix-wifi-bt.sh` | 在已开机的系统里补 WiFi/BT 固件（不用重刷） |
| `port/rootfs-common/sddm-autologin.conf` | 跳过 SDDM greeter，直接进 Plasma |
| `port/rootfs-common/chopin-scp-start.sh` | 启动 SCP 核（没有它就没有传感器） |
| `port/rootfs-common/chopin-scp.service` | 上者的 systemd oneshot |
| `port/rootfs-common/chopin-rotate-kde` | 自动旋转守护进程（KDE/kscreen-doctor 后端） |

### 产物

| 文件 | 说明 |
| --- | --- |
| `work/debian-base/rootfs.img` | Debian 13 base，ext4，写 userdata |
| `out-scp-v123-rootfs/boot-stockdt.img` | 18 MB，纯启动器（`md5 3bbc90236cdf58c9075a655587bb2f2d`） |
| `out-scp-v121-alpine/boot-stockdt.img` | 54.5 MB，带 Alpine，回滚用 |

---

## 10. 踩过的坑（按代价排序）

| 坑 | 后果 | 现在怎么防 |
| --- | --- | --- |
| `.incbin` 的 DTB 没有重建规则 | DT 改动静默失效两个构建周期 | `build-kernel.sh` + 内嵌 FDT 自检 |
| 宿主机没 root 解 tar 丢属主 | systemd 拒绝启动 | 装包 + `mke2fs -d` 全在容器内做 |
| apt 卡在一个 43 MB 半截下载 | 整条队列堵死，9 MB/min | `Acquire::Retries=10` + 20 s 超时；`KEEP=1` 保留容器续跑 |
| `$pkgs` 里的换行 | `systemd-sysv: command not found` | 插值前 `printf '%s ' $pkgs` 压成一行 |
| 双引号里的 `$f` 被外层展开 | `f: unbound variable` | 内层变量写 `\$f` |
| `deb822` 源格式 | `sed sources.list` 不生效，固件包找不到 | 改 `Components:` 行 |
| `plasma-workspace-wayland` 不存在 | apt 整体退出 | trixie 的 Wayland 会话在 `plasma-workspace` 里 |
| initramfs 没做 fwload | WiFi/BT 固件缺失，驱动放弃 | v123 的 init 已移植 |

## 6.6b ⛔ 挂起绝对禁止（含实测后果）

挂起在本移植上**不可用且有害**，不要尝试：

* `mtu3`（USB gadget/串口控制台）拒绝休眠 → 挂起必然失败；
* 显示 doze 路径在挂起时会关掉面板却让 DSI 继续跑 → `buffer underrun` → 花屏；
* **反复测试会造成 LCD 边缘烙印**（2026-10-30 实测，v127/v128 两次测试后出现）。

保护措施（已固化进 `chopin-provision.sh`）：

```ini
# /etc/xdg/autostart/chopin-no-suspend.desktop
Exec=gnome-session-inhibit --inhibit suspend --reason "suspend is unsupported" sleep infinity
```

实测：`systemctl suspend` → `Call to Suspend failed: Access denied`。

⚠️ 抑制锁**挡不住 root 直接 `echo mem > /sys/power/state`** —— 不要那样做。

完整分析见 `port/SUSPEND-ANALYSIS.md`。

## 6.6c 音频（MT6359 + MT6893 AFE）

**驱动一直是好的**，声卡在开机时就注册了：

```
$ cat /proc/asound/cards
 0 [mt6893mt6359   ]: mt6893_mt6359 - mt6893_mt6359
$ aplay -l
card 0: mt6893mt6359, device 0: Playback_1
```

内核配置（已开）：

```
CONFIG_SND_SOC_MT6893_MT6359=y
CONFIG_SND_SOC_MT6359=y
```

### 没有声音的唯一原因：默认输出被静音且音量 0

```sh
$ runuser -u kily -- env XDG_RUNTIME_DIR=/run/user/1000 \
    wpctl status | sed -n '/Sinks:/,/Sources:/p'
 ├─ Sinks:
 │  *   49. Built-in Audio Stereo    [vol: 0.00 MUTED]
```

修复：

```sh
wpctl set-mute   @DEFAULT_AUDIO_SINK@ 0
wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.75
```

验证（能听到 3 秒 440 Hz）：

```sh
python3 -c 'import struct,math,wave
w=wave.open("/tmp/t.wav","wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
for i in range(48000*3):
    v=int(12000*math.sin(2*math.pi*440*i/48000)); w.writeframesraw(struct.pack("<hh",v,v))
w.close()'
pw-play /tmp/t.wav
```

或用 `apt install alsa-utils` 后 `speaker-test -D hw:0,0 -c 2 -t sine -l 1`。

WirePlumber 会把音量/路由保存在 `~/.local/state/wireplumber/`，重启后保持。

**注意**：DTS 里没有外置扬声器功放 GPIO，走的是 MT6359 内部功放通路；
`amixer -c 0` 里只有 codec 内部的 `Amp Gain ZC` / `Soft Ramp` 之类控件。

## 6.7 卸载 KDE（可选，释放约 2.5 GB）

GNOME 验证稳定后可以清掉 KDE。**注意 `sddm` 的 purge 会删掉
`display-manager.service` 这个 alternative 符号链接**，之后开机不进桌面
（黑屏、无会话），必须重建：

```sh
DEBIAN_FRONTEND=noninteractive apt-get purge -y \
    kde-plasma-desktop plasma-desktop plasma-workspace \
    kwin-wayland kwin-x11 sddm konsole dolphin
DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y

# 剩余的 KF5/KF6 库被标记为 manual，autoremove 不动，需要按模式清：
apt-get purge -y 'plasma-*' 'kde-*' 'kwin*' 'kscreen*' 'libkf5*' 'libkf6*' \
    'kf6-*' 'kio-*' kded6 'qml6-module-org-kde-*' 'polkit-kde-*' \
    'xdg-desktop-portal-kde' 'breeze*' 'sddm*' 'dolphin*' 'konsole*' \
    'kate*' 'okular*' 'kmenuedit*' 'systemsettings*'
apt-get autoremove --purge -y

# 关键：恢复显示管理器
ln -sf /usr/lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service
printf '/usr/sbin/gdm3\n' > /etc/X11/default-display-manager
systemctl daemon-reload && systemctl reboot
```

实测效果：包数 547+127 移除，磁盘 **5.9G → 3.4G**（释放 2.5 GB），
重启后正常自动进入 GNOME。

**验收判据**（都要满足）：

```sh
pgrep -c gnome-shell                              # ≥1
systemctl is-active gdm                           # active
journalctl -b -u gdm | grep -c "never registered" # 0
dmesg | grep -c "layer_info is null"              # 0
dpkg-query -W -f='${Package}\n' | grep -cE '^(plasma|kde|kwin|libkf|sddm)'  # 0
```
