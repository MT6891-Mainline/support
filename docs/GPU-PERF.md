# GPU 性能现状与提频失败分析

> 2026-10-30。结论：**GPU 固定 350 MHz，无法安全提频，保持现状。**

## 1. 现状：GPU 没有 DVFS，锁在 350 MHz

```
panfrost 13000000.mali: clock rate = 349999848
panfrost 13000000.mali: bus_clock rate = 0
panfrost 13000000.mali: mali-g77 id 0x9080 ... shader_present=0x660067

$ ls /sys/class/devfreq/          # 空：没有任何调频设备
$ grep mfg /sys/kernel/debug/clk/clk_summary
  mfgpll     349999848 Hz
  mfg_sel    349999848 Hz   消费者 13000000.mali
  mtcmos_mfg*  enabled     消费者 13000000.mali
```

基准成绩：**glmark2-es2-wayland -s 800x600 = 1919**。

Mali-G77 MC9 在 MT6893 上可到 ~850 MHz，350 MHz 约为 **41%**。

## 2. 为什么没有 DVFS

mali 节点没有 `operating-points-v2`。panfrost 的
`panfrost_devfreq_init()` 在 `dev_pm_opp_of_add_table()` 返回 `-ENODEV` 时
**直接放弃注册 devfreq**（这是主线的可选路径），于是频率永远是 bootloader
（LK）编程的 `mfgpll` 值。

## 3. 三次提频尝试与失败

| # | 做法 | 结果 |
| --- | --- | --- |
| 1 | DT 加 `operating-points-v2`（350/450/550/650/750MHz）→ devfreq | **内核挂在 initramfs 之前**（SSH 与 USB 串口全无） |
| 2 | 手动 `echo 450000000 > .../core_clk_rate`（运行时） | **系统冻结**，需重启 |
| 3 | 保持不动 | 350MHz，稳定 |

### 失败机制

`panfrost_devfreq_init()` 里：

```c
cur_freq = clk_get_rate(pfdev->clock);             /* 349999848 Hz */
opp = devfreq_recommended_opp(dev, &cur_freq, 0);  /* 表里精确的 350000000 */
```

两者差 152 Hz，于是去 `clk_set_rate()` **重新锁定 `mfgpll`**。
而 GPU 此刻正从该 PLL 实时取时钟（MTCMOS MFG 与 AXI 都使能），
MTK PLL 重锁需要输出静止，relock 瞬态导致时钟毛刺 → **AXI 总线停顿** →
之后任何 GPU 寄存器访问都挂死。

所以问题不在 OPP 表本身，而在 **"带着 GPU 重锁 PLL" 这个动作**。

## 4. 真要提频需要什么

1. **quiesce GPU**：关闭 MTCMOS MFG 各域、停 AXI/总线时钟、必要时拉 GPU 复位；
2. 再 `clk_set_rate(mfg_sel/mfgpll)`；
3. 恢复时钟与电源域，重新初始化 GPU。

这正是厂商 `mtk_gpufreq`（本树未移植）做的事，而且它还有
**频率-电压对照表**（`gpufreq-supply` → MT6359 `vgpu11`）。
当前 `vgpu11` 固定 0.75 V，看起来是厂商的高档电压，但**没有表就无法确认**
每个频点对应的安全电压。

另外 `bus_clock rate = 0` 也说明 GPU 总线时钟没有模型化，提频后可能成为新瓶颈。

## 5. 当前建议

**保持 350 MHz。** 理由：

* 提频需要移植厂商 gpufreq 的 quiesce/relock 序列 + 电压表，工作量和风险都不小；
* 每次失败都要重新刷机（且看不到日志，没有硬件 UART）；
* 这块屏刚受过伤，不适合反复折腾；
* 350MHz 的 G77 对日常桌面已经完全够用。

## 6. 相关镜像

| 镜像 | 说明 |
| --- | --- |
| `out-scp-v130-rootfs` | 已知正常基准 |
| `out-scp-v131-rootfs` | ⛔ 含 OPP 表，**开机挂死**，不要使用 |
| `out-scp-v132-rootfs` | ⛔ 含运行时旋钮，**写它就会挂死**，不要使用 |
| `out-scp-v133-rootfs` | ✅ 已移除旋钮与 OPP 表，等同 v130 + 本次诊断结论 |

v133 的 DTB 大小与 v130 相同（281990 字节），内核 `core_clk_rate` 引用为 0，
即**没有任何提频代码残留在内核里**。

---

## 7. 完整 GPU 链路（2026-10-30，结合历史文档与运行期实测）

### 7.1 上电与时钟

```
LK (bootloader)
 ├─ MT6315 7_vbuck1 设好 GPU 电压        ← SPMI 未绑定，Linux 读不到也改不了
 └─ mfgpll = 349999848 Hz                ← GPU 时钟源，之后无人修改

Linux panfrost probe:
 topckgen mfg_sel   ← mux，可选父：clk26m / mfgpll / univpll_d6 / mainpll_d5_d2
    当前父 = mfgpll
      ↓
 chopin_gpu_rails_on()    vsram_others / vgpu11（0.75 V，LK 已打开）
 chopin_mtcmos_on()       7 个 MTCMOS 门控：
                          mtcmos_mfg_async → mfg → core0/1_2/3_4/5_6/7_8
 chopin_mfg_axi_config()  写 0x13fbf020/0x02c/0x0b0/0x0b4/0x024
                          （vendor mt_gpufreq_external_cg_control() 的等价物：
                            MEM0/1 端口门控、清 free-run、开 Q-channel、FAXI SOC-in）
      ↓
 clock rate = 349999848, bus_clock rate = 0
      ↓
 Mesa G77（自编 libgallium-25.0.7）硬件渲染
```

### 7.2 为什么停在 350 MHz：三个缺口

| # | 缺口 | 证据 | 难度 |
| --- | --- | --- | --- |
| ① | PLL 安全重锁 | 带载 `clk_set_rate` 重锁 mfgpll → AXI 停顿 → 系统挂死（实测两次） | 中，可做：mfg_sel 有 clk26m 可中转 |
| ② | **GPU 电压控制** | `ls /sys/bus/spmi/devices/` 为空、`dmesg` 里没有 spmi 任何输出 → MT6315 `7_vbuck1` 完全不可达 | **高**：要移植 SPMI 控制器 + mtk-spmi-pmic + mt6315-regulator |
| ③ | 总线/互联 DVFS | `bus_clock rate = 0`，GPU 总线时钟未建模 | 高 |

**② 是硬阻塞**：只提频率不提电压 = 欠压。350 MHz 的电压驱动 750 MHz 必然不稳。
所以 ① 单独做出来也**不能安全使用**，它的价值是把"往后再做 DVFS"的前置条件准备好。

### 7.3 真实瓶颈可能不是核心频率

glmark2 分项（800x600，350 MHz）：

| 场景 | FPS | 性质 |
| --- | --- | --- |
| conditionals / function / loop | 2500–3100 | 计算密集，**很宽裕** |
| jellyfish / shadow | 1349–1678 | 中等 |
| buffer / terrain / refract | 80–205 | **内存带宽受限** |

计算密集场景跑到 3000 FPS，说明 350 MHz 的 G77 计算能力远没用满；
拖后腿的是内存/带宽路径（正好落在 ②/③ 管辖的范围）。
对真实 GUI（合成、纹理、滚动）而言，单纯提核心频率的收益会比直觉小。

### 7.4 结论

保持 350 MHz。若要推进，按 ① → ② → ③ 的顺序，且 ② 是真正的门槛。

## 8. ① 的实现：mfg_sel 中转重锁

思路（与 vendor `mtk_gpufreq` 同类）：

```
clk_set_parent(mfg_sel, clk26m)   → GPU 降到 26 MHz，PLL 无消费者
clk_set_rate(mfgpll, new_hz)      → 安全重锁
clk_set_parent(mfg_sel, mfgpll)   → 切回新频率
```

框架直接 `clk_set_rate(mfg_sel)` 会在 mux 仍指向 PLL 时就抬高 PLL 频率，
这正是之前挂死的原因。

### 8.1 实现（v134）

DT 侧给 GPU 节点补了两个时钟引用：

```dts
clocks = <&topckgen MFG_SEL>,   /* 0x69, "core" */
         <&g3d_config 0>,
         ... 7 个 MTCMOS ...
         <&apmixed 0x0b>,       /* CLK_APMIXED_MFGPLL = 11 → "core_pll" */
         <&clocks/clk26m>;      /* "core_slow" */
```

驱动侧（`panfrost_device.c`）：

```c
static int chopin_gpu_set_rate(pfdev, hz)
{
	ret = clk_set_parent(pfdev->clock, core_slow);   /* → 26 MHz */
	if (ret) return ret;
	ret = clk_set_rate(core_pll, hz);                /* 无消费者，安全重锁 */
	if (clk_set_parent(pfdev->clock, core_pll))      /* 切回 */
		return -EIO;
	return ret;
}
```

暴露成 `/sys/devices/platform/13000000.mali/core_clk_rate`：
读返回当前频率，写触发上面三步。**启动路径完全不调用它**，
所以即使三步里有问题也不会影响开机。

### 8.2 验证方法

```sh
# 1) 确认能读到
cat /sys/devices/platform/13000000.mali/core_clk_rate      # 349999848

# 2) 小步试：450 MHz
echo 450000000 > /sys/devices/platform/13000000.mali/core_clk_rate
cat  /sys/devices/platform/13000000.mali/core_clk_rate

# 3) 有提升就测成绩
runuser -u kily -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
  glmark2-es2-wayland -s 800x600 -b :duration=1 | tail -3
```

判据：

* 系统存活 + `cat` 显示 450000000 → 重锁成功，可以继续 550/650
* **系统挂死** → mux 切换本身也不安全，此路终止，刷回 v133

### 8.3 重要限制（必须记住）

即使 ① 成功，**也不应该长期在 450 MHz 以上运行**：

* GPU 电压由 MT6315 `7_vbuck1` 提供，SPMI 未绑定，Linux **改不了电压**；
* 电压是 LK 按 350 MHz 设定的，提频不提压 = 欠压；
* 短时间跑分可能看不出来，高负载持续运行会不稳定。

所以 ① 的定位是：**验证"安全重锁"这条路可行**，为将来做完 ②（SPMI/MT6315）
之后铺路，而不是现在就拿去日常高频运行。

### 8.4 实测结果（v134，2026-10-30）

安全重锁**成功**，三次提频都没有挂死：

```
$ cat /sys/devices/platform/13000000.mali/core_clk_rate
349999848
$ echo 450000000 > /sys/devices/platform/13000000.mali/core_clk_rate
$ cat /sys/devices/platform/13000000.mali/core_clk_rate
449999634                      ← 重锁成功，系统存活
```

glmark2-es2-wayland（800x600，`:duration=1`）：

| 频率 | Score | 相对 350 |
| --- | --- | --- |
| 350 MHz | 1919 | — |
| 450 MHz | 1994 | +3.9% |
| **650 MHz** | **2139** | **+11.5%** |
| 750 MHz | 2060 | +6.9%（**低于 650**） |

稳定性：650 MHz 跑完整 glmark2 套件（约 2 分钟），
`gpu sched`/`fault`/`reset` 计数 **0**，跑完频率仍是 650000000。

### 8.5 结论

1. **① 可行**：mfg_sel → clk26m → 重锁 mfgpll → 切回，这条路径安全。
   之前两次挂死确实是"带着 GPU 重锁 PLL"造成的，不是 PLL 本身不可改。
2. **收益很小**：频率 +86% 只换来 **+11.5%** 分数。印证了 §7.3 的判断——
   瓶颈在内存/带宽，不在核心频率。
3. **750 MHz 反而更慢**，是欠压/临界运行的信号：
   GPU 电压由 MT6315 提供、Linux 改不了，电压是按 350 MHz 设的。
4. 唯一的 thermal zone 是电池电量计（`bq27z561-0`），**没有 SoC 温度传感器**，
   无法监控发热。

### 8.6 持久化（可配置、可撤销、无需刷机）

`/usr/local/bin/chopin-gpu-freq` + `chopin-gpu-freq.service`（已加入 provisioning）：

* 服务在 `gdm.service` 之前运行（GPU 空闲，mux 短暂降到 26 MHz 不会打断任务）；
* 读取 `/etc/chopin-gpu-freq`（纯数字，单位 Hz）；
  **文件不存在时服务自动跳过**，保持 bootloader 的频率。

启用 / 关闭：

```sh
echo 650000000 > /etc/chopin-gpu-freq && systemctl restart chopin-gpu-freq   # 开
rm -f /etc/chopin-gpu-freq && systemctl stop chopin-gpu-freq                 # 关
```

**建议值：650**（实测最佳且稳定）。**不要用 750**（更慢，说明临界）。

---

## 9. ② 和 ③ 能不能抬升 GPU 上限？（2026-10-30 分析）

### 9.1 结论

| 缺口 | 抬升的是 | 收益估计 | 工作量 |
| --- | --- | --- | --- |
| ② 电压（SPMI/MT6315） | **计算上限** | ~20–25%（实测频率 +86% 只 +11.5%） | 大（SPMI + PMIC + regulator glue） |
| ③ 互联/DDR 带宽 | **真实上限**（带宽） | 可能 50%+ | 更大（四步，见 9.3） |

**② 不值得**：计算密集场景已经 2500–3100 FPS，远未吃满；
频率翻倍也只有 11.5% 的端到端收益。

**③ 才是真瓶颈**：内存受限场景（buffer/terrain/refract）只有 80–205 FPS。

### 9.2 现状：DDR 侧完全没有 DVFS

```
$ ls /sys/class/devfreq/            # 空
$ grep -iE "^ *(emi|mempll|ddr)" /sys/kernel/debug/clk/clk_summary
mmpll_* ...                          # 只有 mmpll 分频，没有 emi/ddr 时钟
```

`emit_mng_init` 只打印地址，是厂商 EMI 管理器，不参与调频。
DDR 频率是 LK 设定的，Linux 既读不到也改不了。

### 9.3 ③ 的可行性（比预期好，也比预期大）

**好消息**：主线 DVFSRC **完整支持 MT6893**：

```c
/* drivers/soc/mediatek/mtk-dvfsrc.c */
static const struct dvfsrc_soc_data mt6893_data = {
	.opps_desc = dvfsrc_opp_mt6893_desc,      /* DRAM/EMI/vcore 各档 */
	.set_dram_bw = dvfsrc_set_dram_bw_v1,     /* 带宽请求接口 */
	.set_dram_peak_bw = ...,
	.get_current_level = dvfsrc_get_current_level_v2,
	...
};
{ .compatible = "mediatek,mt6893-dvfsrc", .data = &mt6893_data },
```

**坏消息**：需要四步，缺一不可：

| # | 步骤 | 现状 |
| --- | --- | --- |
| 1 | `CONFIG_MTK_DVFSRC=y` + DTS 加 `"mediatek,mt6893-dvfsrc"` | 未编译；DTS 是 vendor compatible `"mediatek,dvfsrc"` |
| 2 | `CONFIG_INTERCONNECT_MTK=y` + **写 mt6893 的 ICC 拓扑** | 只有 mt8183/mt8195/mt8196，**没有 mt6893** |
| 3 | panfrost 增加 ICC 带宽投票 | panfrost **完全没有 ICC 代码** |
| 4 | 显示侧带宽投票（v2 DRM 的 mmqos） | 厂商 mmqos 未移植 |

第 3、4 步是关键：DVFSRC 只是"收集请求"，
**没有人请求带宽，DDR 就不会升频**。

### 9.4 建议的下一步：只做第 1 步（零风险）

启用 DVFSRC + DTS 加 compatible，然后**只读** debugfs：

```sh
cat /sys/kernel/debug/dvfsrc/current_level
```

价值：

* 得知 LK 把 DDR 留在哪一档（若是最低档，③ 的收益会非常大）
* 验证 DVFSRC 在本板能否 probe
* **不改变任何频率/电压**

注意：**不要同时启用 `CONFIG_MTK_DVFSRC_REGULATOR`**——
它会注册 vcore/vscp 调节器，可能让其它驱动开始对电压发请求。

### 9.5 第 1 步实测（v135 → v136）

**v135**（只开 `CONFIG_MTK_DVFSRC` + 加 compatible）：驱动 probe **失败**：

```
mtk-dvfsrc 10012000.dvfsrc: error -ENOENT: Couldn't get and enable DVFSRC clock
mtk-dvfsrc 10012000.dvfsrc: probe with driver mtk-dvfsrc failed with error -2
```

原因：驱动用 `devm_clk_get_enabled(dev, NULL)`，**硬要求一个时钟**，
而厂商 DTS 节点只有 `reg` + `interrupts`。

**v136**：补 `clocks = <&topckgen CLK_TOP_DVFSRC_SEL>`（index 149）。

驱动随后的流程（`mtk_dvfsrc_probe`）：

```c
	arm_smccc_smc(MTK_SIP_DVFSRC_VCOREFS_CONTROL, MTK_SIP_DVFSRC_INIT, ...);
	...
	arm_smccc_smc(MTK_SIP_DVFSRC_VCOREFS_CONTROL, MTK_SIP_DVFSRC_START, ...);
```

**这一步依赖 stock ATF 实现该 SIP**。如果 ATF 不认，会报
`DVFSRC init failed` / `Cannot start DVFSRC`——那也就直接说明
这块板子无法使用 DVFSRC 的带宽通路，③ 到此为止。

判据：

| v136 日志 | 含义 |
| --- | --- |
| 无 dvfsrc 报错 + `/sys/kernel/debug/dvfsrc/` 出现 | ✅ 可用，读档位判断收益 |
| `DVFSRC init failed: N` | stock ATF 不支持该 SIP → ③ 不可行 |
| 仍报时钟错误 | 时钟 index 不对，需查 topckgen |

### 9.6 第 1 步的结论：DVFSRC 不能单独启用（2026-10-30 实测）

v136 补了 MCU 时钟后，DVFSRC **确实绑定了**（`10012000.dvfsrc → mtk-dvfsrc`，
无报错），但代价是显示直接坏掉：

```
[ 1.513854] [cmdq] failed to get mediatek,smi          ← 带宽通路断了
[12.712842] [DISP][E][IRQ] DDP_COMPONENT_OVL0: frame underflow! cnt=0
[12.729590] ... cnt=1
[12.745970] ... cnt=2
   ... 70 秒内 3530 次 underflow → 屏幕持续花屏
```

机制：DVFSRC probe 通过 `arm_smccc_smc(MTK_SIP_DVFSRC_START)` 让 **MCU 接管
带宽调度**，但此时**没有任何投票者**（panfrost 没有 ICC 代码、显示侧没有 mmqos、
ICC 也没有 mt6893 拓扑），于是 DRAM/EMI 被降到低档，显示管线饿死。

**这直接判定了 ③ 的可行性**：DVFSRC 不是一个可以"先开起来看看"的东西——
开启它就立刻改变带宽调度。要安全启用，必须在**同一步**里补齐：

1. ICC 拓扑（mt6893）
2. panfrost 的带宽投票
3. 显示侧的带宽投票（mmqos）
4. DVFSRC 本身

中间没有安全的检查点。所以 ③ 是"要么全做、要么不做"的项目，
不能像 ① 那样增量验证。

### 9.7 回退

已撤销两个 DVFSRC 提交（`d486cad9b`、`40cf3c55c`）并关闭
`CONFIG_MTK_DVFSRC`，产出：

* `out-scp-v134-rootfs`：① 完成后的已知良好镜像（GPU 频率旋钮 + 安全重锁）
* `out-scp-v137-rootfs`：从撤销后的树重新构建，行为等同 v134

**不要使用 v135 / v136**（会持续 underflow 并花屏）。

---

## 10. ③ 的最终结论：带宽已在上限，无法提升（2026-10-30 实测）

### 10.1 让 DVFSRC 可用的必要修复（v138）

v136 失败的根因是：MCU 接管带宽调度后**停在最低档**，而 `mt6893_data`
**缺 `set_opp_level`**（上游只给 mt8195/mt8196 有），软件无法纠正。
另外上游 `mtk-dvfsrc.c` **完全没有 debugfs**，所以"读档位"这条路本来就不存在。

v138 做了三件事：

| # | 改动 |
| --- | --- |
| 1 | `mt6893_data` 接上 `set_opp_level = dvfsrc_set_opp_level_v1` |
| 2 | `DVFSRC_START` 之后立刻把档位钉到 `num_opp - 1` |
| 3 | 新增 debugfs `/sys/kernel/debug/dvfsrc/level`（可读可写） |

### 10.2 实测结果

```
$ cat /sys/kernel/debug/dvfsrc/level
16                                       ← MCU 已按请求升档
$ dmesg | grep -c underflow
2                                        ← 只有开机瞬态，不再饥饿
$ pgrep -c gnome-shell
2                                        ← 桌面正常，不花屏
```

**显示不再被饿死** —— "启动后钉住档位"这个思路是对的。

但是性能：

| 状态 | glmark2 |
| --- | --- |
| v134 基线（350 MHz，无 DVFSRC） | 1919 |
| v138（350 MHz，DVFSRC level 16） | **1839** |
| 写 `level 23` 后 | 写不进去，仍 16 / 1910 |

### 10.3 两点关键发现

**① MCU 把档位钳在 16，不接受 23**

OPP 表有 24 档（`{vcore, dram}` 从 `{0,0}` 到 `{4,7}`）。level 16 = `{1, 4}`，
而最高是 `{4, 7}`。写 23 读回来还是 16 —— 说明 DRAM 档位受 **MCU 自己的策略**
限制（功耗/温度/DRAM 类型），软件无法突破。

**② 升到 MCU 允许的最高档，性能也没有提升**

这说明 **LK 本来就把 DDR 放在接近 MCU 上限的档位**，不存在"被压制在低档"的情况。
带宽瓶颈是**硬件 DDR 的真实上限**，不是软件调度问题。

### 10.4 为什么不保留 v138

MCU 会在负载/温度变化时**自己降档**。一旦降档，显示立刻饿死 → 回到 v136 的花屏，
而且表现为"平时正常、高负载时突然花屏"，比现状更糟。
既然没有性能收益，就不该承担这个风险。

### 10.5 镜像

| 镜像 | 说明 |
| --- | --- |
| `out-scp-v134-rootfs` | ✅ ① 完成，GPU 频率旋钮，已知良好 |
| `out-scp-v137-rootfs` | ✅ 同上（从撤销后的树重建） |
| **`out-scp-v138-rootfs`** | ⚠️ DVFSRC 可用且有 debugfs，但**无收益 + 有降档花屏风险** |
| **`out-scp-v139-rootfs`** | ✅ **推荐**：DVFSRC 关闭，其余同 v134 |

驱动补丁保留在树里（`0f93fae6a`），将来想继续试验只需
`scripts/config -e MTK_DVFSRC` 重新打开。

### 10.6 三个缺口的最终裁决

| 缺口 | 结论 | 依据 |
| --- | --- | --- |
| ① PLL 安全重锁 | ✅ **完成** | 350→650 MHz，+11.5%，稳定 |
| ② GPU 电压（SPMI/MT6315） | ❌ 不建议 | 工程大；即使做完，纯频率收益也只有 ~20% |
| ③ 带宽（DVFSRC/ICC） | ❌ **已证明无收益** | DDR 已在上限；升档无提升；且有花屏风险 |

**GPU 上限就是现在这样**：350 MHz（或可选 650）+ G77 硬件渲染，
受限于这台设备的 DDR 带宽与无法控制的 GPU 电压。

### 10.7 组合测试：GPU 频率 + DVFSRC（2026-10-30）

在 v138（DVFSRC level 16 钉住）上叠加 GPU 频率旋钮，每档跑 3 次取中位数：

| 配置 | 三次成绩 | 中位数 | 相对 350 基线 |
| --- | --- | --- | --- |
| 350 MHz（默认） | — | 1919 | — |
| 350 MHz + DVFSRC 16 | — | 1839 | -4% |
| **650 MHz + DVFSRC 16** | 2089 / 2103 / 2055 | **2089** | **+9%** |
| 750 MHz + DVFSRC 16 | 2047 / 2053 / 2079 | 2053 | +7% |
| 650 MHz（无 DVFSRC，单次） | — | 2139 | +11% |

**结论**：

1. **650 MHz 是最佳档**，750 略差（~1.7%），与无 DVFSRC 时的结论一致 → 750 是欠压临界。
2. **DVFSRC 没有可测收益**（650 时 2089 vs 2139，在 ±5% 噪声内）。
3. 之前"750 比 650 慢 6.9%"的现象在 DVFSRC 下变成"慢 1.7%"，
   说明部分差距确实来自带宽，但**远不足以抵消欠压代价**。

**最终推荐组合**：

```
boot 镜像: out-scp-v139-rootfs（DVFSRC 关闭）
GPU 频率:  /etc/chopin-gpu-freq = 650000000（chopin-gpu-freq.service 开机应用）
预期:      glmark2 ~2100（+9%），显示稳定，无 MCU 降档风险
```

不采用 DVFSRC 的理由：无收益 + MCU 可能自降档导致显示饿死（v136 已实测过该后果）。

---

## 11. 重要更正：全屏负载下频率收益是 +70%，不是 +11%

### 11.1 之前结论错在哪里

§8.4 用 `glmark2 -s 800x600` 测出"频率 350→650 只 +11.5%"，并据此认为
"瓶颈在带宽、频率无意义"。**这个结论是错的**：800x600 只有 48 万像素，
在这么小的窗口里 CPU、驱动开销和 vsync 掩盖了 GPU 的差异。

**1080x2400（面板全屏，260 万像素）才是真实负载。**

### 11.2 正确的频率曲线（1080x2400，`:duration=1`）

| 频率 | 实际达成 | 分数 | 相对 350 |
| --- | --- | --- | --- |
| 350 MHz | 349999848 | 919 | — |
| 550 MHz | 549999817 | 1257 | +36.8% |
| 650 MHz | 650000000 | 1403 | +52.7% |
| 750 MHz | 749999390 | 1504 | +63.7% |
| **810 MHz** | **809999817** | **1563** | **+70.1%** |
| 836 MHz | 835999817 | 1570 | +70.8% |

* 曲线**单调上升**，说明"750 比 650 慢"是 800x600 下的假象（那里测的是噪声）。
* 810 之后饱和：836 只多 0.4%。
* **全程 `gpu sched` / `fault` / `reset` 计数为 0**。

### 11.3 结论与推荐

**推荐 810 MHz**：

* 相对 350 有 **+70%** 的真实提升
* 836 需要更接近极限的 PLL/时序，只换来 0.4%，不值得
* 留一点余量给温度和器件差异

配置：

```sh
echo 810000000 > /etc/chopin-gpu-freq     # chopin-gpu-freq.service 开机应用
```

### 11.4 关于欠压风险（修正后）

之前担心"电压按 350 MHz 设定，提频是欠压"。实测 836 MHz 下 0 错误、
曲线单调，说明 LK 设的电压（MT6315 7_vbuck1）**本来就是按高档位设的**
（很可能 LK 初始化 GPU 时用的是高电压，之后只降了频率）。

仍需注意：**没有 SoC 温度传感器**，长时间高负载无法监控发热。
建议观察机身温度，必要时降到 650。

### 11.5 对三个缺口的重新裁决

有了正确数据后，之前的裁决需要修正：

| 缺口 | 原结论 | 修正后 |
| --- | --- | --- |
| ① PLL 安全重锁 | ✅ +11.5% | ✅ **+70%**（全屏），价值远超预期 |
| ② GPU 电压 | ❌ 收益小 | ❌ **已经不需要**：我们不用改电压就能到 **836 MHz**，那正是 MT6891 G77 的上限，再往上没有硬件余量 |
| ③ 带宽（DVFSRC） | ❌ 无收益 | ❌ 维持：DVFSRC 实测无收益且有降档风险 |

**所以 GPU 性能这条线现在算是真正做完了**：

* 频率：350 → **810 MHz**（+70%，可到 836）
* 不需要 SPMI/MT6315 电压控制
* 不需要 DVFSRC
* 剩下的唯一变量是**发热**（没有 SoC 温度传感器可读）

### 11.6 最终配置

| 项 | 值 |
| --- | --- |
| boot 镜像 | `out-scp-v139-rootfs`（DVFSRC 关闭） |
| GPU 频率 | `/etc/chopin-gpu-freq` = `810000000` |
| 服务 | `chopin-gpu-freq.service`（enabled，gdm 之前应用） |
| 预期 | 全屏 glmark2 ≈1560（+70%），800x600 ≈2080 |

---

## 12. 测量方法论修正与最终数据（2026-10-30）

### 12.1 之前几组数据为什么互相矛盾

同一配置反复测出现过 1354 / 1533 / 1700 这样的波动（±12%），原因有两个：

1. **首轮偏低**：改完频率后第一次跑明显偏慢（1533 vs 后续 1700+），
   GPU 驱动/电源需要一小段稳定时间。
2. **连续扫频会累积发热**：一次跑 6 档、每档 1 分钟，后面的档位被热节流压低，
   于是出现"650 比 550 还低"这种非单调结果。

### 12.2 正确的测量方法

* 每档先跑一次**丢弃**（预热）
* 连续测 3 次取中间值
* **不要**在一次会话里连续扫很多档

### 12.3 最终数据（v139，无 DVFSRC，预热后，1080x2400）

| 频率 | 有效测量 | 相对 350 |
| --- | --- | --- |
| 350 MHz | 967 / 968 | — |
| **810 MHz** | **1700 / 1715 / 1714** | **+77%** |

`underflow = 2`（开机瞬态），**没有任何 GPU fault / sched timeout**。

### 12.4 DVFSRC 的最终定论

v138（DVFSRC 钉 16 档）单次测得 1563，v139（关闭）预热后 1710。
但 v138 那次是在扫频中途测的，受 §12.1 的干扰，**两者不能直接比较**。

既然：

* DVFSRC **没有可复现的收益**
* 它有**明确的失败模式**（MCU 停在最低档 → 显示持续 underflow → 花屏，v136 已实测）

**最终选择 v139（DVFSRC 关闭）**，不再回头。

### 12.6 A/B 定论：DVFSRC 让性能下降 22–40%（2026-10-30）

用**完全相同**的协议（设定频率一次 → 预热丢弃 → 连跑 3 次取中值，
1080x2400，`:duration=1`）对比两个镜像：

| 配置 | 810 MHz | 350 MHz |
| --- | --- | --- |
| **v139（无 DVFSRC）** | 1700 / 1715 / 1714 → **1714** | 967 / 968 → **968** |
| v138（DVFSRC level 16） | 1220 / 1152 / 1224 → **1220** | 756 / 829 → **790** |

**v139 在 810 MHz 快 40%，在 350 MHz 快 22%。**

原因：DVFSRC 把 DDR 钉在 **level 16 = `{vcore 1, dram 4}`**，
而 OPP 表最高是 `dram 7`。**LK 原本设的档位比 16 档更高**，
MCU 接管后反而降低带宽；写 23 又会被 MCU 钳回 16，追不回来。

所以 v136 的花屏不只是"没人投票"——是 MCU 直接把 DDR 压到比原来更低的档位。

**结论：DVFSRC 必须保持关闭。** 之前的"扫频对比"（v138 1563 vs v139 1354）
因测量协议缺陷得出了相反的错误结论，已由本节 A/B 纠正。

### 12.5 最终状态

| 项 | 值 |
| --- | --- |
| boot 镜像 | `out-scp-v139-rootfs` |
| GPU 频率 | 810 MHz（`/etc/chopin-gpu-freq`，开机由 service 应用） |
| 全屏 glmark2 | ~1710（350 MHz 时 968） |
| 相对提升 | **+77%** |
| 稳定性 | 0 GPU 错误，显示正常 |
