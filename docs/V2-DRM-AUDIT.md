# mediatek_v2 DRM 审计（2026-10-30）

范围：`drivers/gpu/drm/mediatek/mediatek_v2/`，**73 个 C 文件、110,610 行**。
跑在我们板子上的是这套厂商栈（`CONFIG_DRM_MEDIATEK_V2=y`，Makefile 二选一，
主线 `mediatek/` 不参与编译）。

严重度定义：

* **S1**：内存破坏 / 任意内核读写 / 提权
* **S2**：可稳定触发的功能故障或 DoS
* **S3**：健壮性 / 可维护性问题
* ✅ = 本次移植过程中已修复

---

## 汇总

| # | 问题 | 严重度 | 状态 |
| --- | --- | --- | --- |
| 1 | 38 个 ioctl 无 `DRM_AUTH` 保护（含寄存器读写、PQ、MUTEX_CONTROL） | S2 | 未修 |
| 2 | `MTK_LAYERING_RULE` 的 `layer_num` 无上界 | S2 | 未修 |
| 3 | fence session 表 3 个槽且永不释放 | S2 | ✅ v126 |
| 4 | 挂起/恢复不对称，失败挂起把面板留在关闭状态 | S2 | ✅ v127–v129 |
| 5 | DSI buffer underrun 中断无任何恢复动作 | S2 | 部分（v129 只在 resume 恢复） |
| 6 | CMDQ wakelock 空闲时永不释放 → 系统挂起永远无法完成 | S2 | 未修 |
| 7 | doze 路径用陈旧的 connector 状态 | S3 | 未修 |
| 8 | `mtk_drm_suspend_release_fence` 不校验 session | S3 | ✅ v127 |
| 9 | mmsys 驱动被自己的子设备二次匹配（-EBUSY） | S3 | ✅ v125 |
| 10 | MTCMOS 时钟 provider 只覆盖 index 0..8 | S2 | ✅ v125 |
| 11 | `ncs_tuning_mode` 全局状态被无认证 ioctl 改写 | S3 | 未修 |
| 12 | `sprintf` 写 32 字节栈缓冲 | S3 | 未修（当前不可能溢出） |

**没有发现 S1**：`MTK_LAYERING_RULE` 的用户指针是用 `copy_from_user` 正确处理过的
（见 §2），寄存器读写有白名单校验（见 §1）。

---

## 1. 无认证的 ioctl 面（S2，未修）

`mtk_drm_drv.c:4806` 的 `mtk_ioctls[]` 里，**38 个** ioctl 的 flags 是 `0`
（不带 `DRM_AUTH`），意味着**任何能打开 `/dev/dri/card1` 的进程**都能调用，
不需要成为 DRM master、也不需要认证。

其中值得注意的：

| ioctl | 影响 |
| --- | --- |
| `MTK_WRITE_REG` / `MTK_READ_REG` | 写/读 COLOR0 寄存器（**有 `color_is_reg_addr_valid` 白名单**，不是任意 MMIO） |
| `MTK_MUTEX_CONTROL` | 改全局 `ncs_tuning_mode`（`mtk_disp_color.c:2680`） |
| `MTK_SET_GAMMALUT` / `MTK_SET_PQPARAM` / `MTK_SET_PQINDEX` | 改 PQ 表 |
| `MTK_AAL_*` / `MTK_C3D_*` | 改 AAL/C3D 硬件 |
| `MTK_FACTORY_LCM_AUTO_TEST` | 工厂模式 LCM 测试 |

**实际暴露面**：`/dev/dri/card1` 是 `crw-rw----+ root video`，我们的会话用户
`kily` 在 `video` 组里 —— 所以**会话内任何程序都能调这些接口**。

**建议**：GNOME/mutter 只用标准 atomic 接口，根本不需要这些 vendor ioctl。
最小改动是在 `mtk_ioctls[]` 里给它们加 `DRM_AUTH`（或 `DRM_ROOT_ONLY`），
需要时再单独放开。

## 2. `MTK_LAYERING_RULE` 的 `layer_num` 没有上界（S2，未修）

`mtk_layering_rule_base.c:2086 check_disp_info()` 只检查：

```c
if (layer_num < 0) { ... return -1; }        /* 只挡负数 */
```

随后 `_copy_layer_info_from_disp()`：

```c
layer_size = sizeof(struct drm_mtk_layer_config) * layer_num;
l_info->input_config[disp_idx] = vzalloc(layer_size);   /* 无上界 */
```

传 `layer_num = 0x7fffffff` 会尝试约 170 GB 的 `vzalloc` → 分配失败返回 -ENOMEM，
**不会造成内存破坏**，但属于可反复触发的内存压力/DoS。

**建议**：在 `check_disp_info()` 里加上硬件上限（例如 `MAX_LAYER_COUNT`，通常 32）。

**已排除的误报**：`struct drm_mtk_layering_info` 里含用户指针
（`input_config[3]`、`mml_cfg[3]`），但驱动是
`vzalloc()` + `copy_from_user()` 到内核副本后再使用（`mtk_layering_rule_base.c:2163`），
**不是**直接解引用用户指针。唯一直接 `memcpy` 的路径是 `debug_mode`
（`:2176`），而 ioctl 传入的 `debug_mode` 恒为 0（`layering_rule_start(..., 0, dev)`），
不可达。

## 3. fence session 表泄漏（S2，✅ v126）

`mtk_drm_session.h: MAX_SESSION_COUNT 3`；`_mtk_fence_context[3]` 按 session id
占槽，**永不释放**（`0xffffffff` 只在 `mtk_fence_init()` 写一次，
`mtk_drm_session_destroy()` 不通知 fence 层）。

3 个合成器实例/挂起恢复周期后表满 → `layer_info is null` → 每次提交 `-EFAULT`
→ 屏幕持续扫描旧 buffer。

**已修**：表满时回收槽 0（`mtk_fence.c`），并对 `layer_info` 缺失降级返回
`fence_fd = -1`（`mtk_drm_crtc.c`）。**根治**：从
`mtk_drm_session_destroy()` 调用一个 `mtk_fence_release_session()`。

## 4. 挂起/恢复不对称（S2，✅ v127–v129）

`mtk_drm_sys_suspend()` 在 `wake_state == false`（合成器已 blank）时跳过
`drm_atomic_helper_suspend()`，但**仍然释放 12 个 timeline 的 fence**；
`mtk_drm_sys_resume()` 因为 `suspend_state == NULL` 直接返回。

后果：面板被 blank notifier 关闭、DSI 仍在跑、resume 不恢复 → **每次开机第一次
挂起尝试后花屏**，且因持续错误驱动造成 LCD 图像粘滞。

**已修**：
* v127：`wake_state == false` 时提前返回，不动 fence
* v128：**无条件**快照状态，让 resume 能恢复
* v129：resume 结束后调用 `mtk_disp_recover_all()`（复用 `mtk_drm_esd_recover`）
  做一次完整 disable/enable

## 5. DSI buffer underrun 没有恢复（S2，部分修复）

`mtk_dsi.c:2136`：

```c
if (status & BUFFER_UNDERRUN_INT_FLAG) {
	DDPAEE("[IRQ] %s:buffer underrun\n", ...);        /* 只打印 */
	if (mtk_crtc)
		atomic_set(&mtk_crtc->force_high_step, 1);   /* 只抬带宽 */
}
```

**没有复位、没有重新初始化、没有重启视频流**。链路一旦进入该状态，
控制器会以刷新率持续输出错误像素，直到重启 —— 这是"花屏会持续"的根因。

驱动里已有完整恢复例程 `mtk_drm_esd_recover()`（面板关 → CRTC 关 → CRTC 开 →
面板开），但只有 ESD 检测失败时才调用；**DSI underrun 不会让 ESD 检测失败**。

**建议**：在 underrun 中断里 `schedule_work()` 一次 `mtk_drm_esd_recover()`
（带 2 s 冷却，避免瞬时 underflow 引起闪烁）。v129 只在 resume 时调用，
覆盖不了运行期的链路错误。

## 6. CMDQ wakelock 永不释放（S2，未修）

`mtk-cmdq-mailbox-ext.c`：

```c
if (lock) { if (!cmdq->wake_locked) { __pm_stay_awake(cmdq->wake_lock); ... } }
```

CMDQ **上电时**（`cmdq_init`）持锁、**下电时**释放。而显示空闲时 CMDQ 并不下电，
于是 `cmdq_pm_lock` 一直持有（实测 `active_since` 持续增长到 56 s+）。

`__pm_stay_awake()` 会累加 `combined_event_count`，使 `pm_wakeup_pending()`
恒为真 → 系统挂起在 CPU 冻结阶段永远被中止：

```
Wakeup pending. Abort CPU freeze
```

**建议**：让 CMDQ 在 ring 空闲（`cmdq->mbox_usage == 0`）时释放 wakelock，
或在 DRM 的 idle 路径里显式下电。

## 7. doze 路径用陈旧状态（S3）

`mtk_drm_drv.c:935/960/985` 三个 `mtk_atomic_doze_*` 函数都用
`connector->state->crtc`（**提交前的旧状态**），而不是本次提交的新状态。
合法的"关闭显示"提交会命中：

```
[DISP][E]mtk_atomic_doze_preparation connector has no crtc
```

`continue` 掉了，所以不会崩，但说明 doze 逻辑对 disable 提交没有正确建模。

## 8. `mtk_drm_suspend_release_fence` 不校验 session（S3，✅ v127）

原来无条件对 `private->session_id[0]` 的 12 个 timeline 调
`mtk_release_layer_fence()`；session 未注册时会刷 12 条 `layer_info is null`。
已加 `if (!private->session_id[0]) return 0;`。

## 9. mmsys 子设备二次匹配（S3，✅ v125）

`mtk_mmsys_probe()` 创建的 `mediatek-drm` 子设备继承父 of_node 与资源，
导致 `mtk_mmsys_drv` 又被匹配一次并 `-EBUSY`：

```
mtk-mmsys mediatek-drm.7.auto: error -EBUSY: can't request region [mem 0x14116000]
```

已加 `if (pdev->id != PLATFORM_DEVID_NONE) return -ENODEV;`。

## 10. MTCMOS 时钟 provider 不完整（S2，✅ v125）

`clk-mt6893-pg.c` 只注册 index 0..8（MFG 子集），而显示要 `<&scpsys 20>`：

```
of_clk_hw_onecell_get: invalid index 20
[DISP][E]mtk_drm_get_top_clk get 0 clk failed
```

顶层时钟没配上 → 120 Hz 下高负载 `frame underflow` → 撕裂/花屏。
已扩到 `MT6893_MTCMOS_MAX = 40`（MFG 真实 + 其余 no-op 占位）。

## 11. `ncs_tuning_mode` 全局状态（S3，未修）

`mtk_disp_color.c:2692` 的 `MTK_MUTEX_CONTROL` 无认证地改写全局 `ncs_tuning_mode`，
会影响后续所有显示提交的行为。影响有限（只是调优模式开关），但属于
"未认证进程改全局内核状态"。

## 12. `sprintf` 到 32 字节栈缓冲（S3，未修）

`mtk_fence.c: _get_session_sync_info()` 里多次：

```c
char name[32];
sprintf(name, "%s%d_prepare", mtk_fence_session_mode_spy(session_id), MTK_SESSION_DEV(session_id));
```

`session_id` 受类型/设备号约束，当前不会溢出；但应改为 `snprintf`。

---

## 建议的优先级

1. **S2 #1**（无认证 ioctl）—— 改动最小、收益最大：给 vendor ioctl 加 `DRM_AUTH`
2. **S2 #5**（DSI underrun 恢复）—— 直接决定"出错后能不能自愈"，关系到面板寿命
3. **S2 #6**（CMDQ wakelock）—— 挂起能否可用的前提
4. **S2 #2**（layer_num 上界）—— 一行校验
5. **S3 其余** —— 可随下次改动顺手修

**注意**：#3–#10 都是本次移植过程中真实踩到并修掉的；#1、#2、#5、#6 仍然开着。

---

## 13. 要不要从 v2 迁移到主线 DRM？

### 13.1 结论

**现在不迁。** 剩下的 v2 缺陷都已有明确修法（v130 已完成大部分），而迁移的
**唯一硬阻塞是 DSC**：主线 `mtk_dsi.c` 完全不支持 DSC，而我们的 LCM 是
**DSC video mode**（`l16_36_02_0b_dsc_vdo`）。

### 13.2 主线已经支持的部分（好消息）

| 组件 | 主线状态 |
| --- | --- |
| `mtk-mmsys` | ✅ 有 `mt6893_mmsys_driver_data` + 完整 routing table |
| `clk-mt6893-mm` | ✅ 存在，且 mmsys 会创建该子设备 |
| OVL / RDMA / MUTEX / COLOR / CCORR / AAL / GAMMA / DITHER | ✅ 主线 `mediatek/` 都有对应文件 |
| 我们的面板驱动 | ✅ `panel-k10a-bringup.c` 已经是标准 `drm_panel`（只用 drm/dsi API，不依赖厂商头文件） |
| 标准 atomic 提交 | ✅ 主线天然使用 |

### 13.3 硬阻塞：DSC

```
主线 mtk_dsi.c        grep -c "dsc"  →  0
我们的面板            DSC_ENABLE 1, DSC_VER 17, slice mode 1, 8bpc, line buf 9
```

DSC 是视频带宽压缩（1080x2400@120 不压缩的带宽压力很大，这也是当初
underflow 那么敏感的原因之一）。主线 DSI **没有** DSC 的 PPS 打包与
DSI 压缩模式寄存器配置，要迁移就得先给 `mtk_dsi` 补上 DSC 支持
（`drm_dsc_config` + PPS payload + `DSI_COMPRESSION_MODE` 寄存器），
再改面板驱动改用标准 `drm_dsc_*` 接口。

**这是几百行内核工作 + 在唯一一块已经受伤的屏幕上反复验证**——风险与成本都很高。

### 13.4 迁移能"免费"得到什么

我们这几天修的问题，在主线里**根本不存在这一类**：

| v2 的问题 | 主线为什么没有 |
| --- | --- |
| fence session 表只有 3 个槽、永不释放 | 主线用标准 `drm_syncobj`/atomic，没有自研 session 模型 |
| 挂起/恢复不对称、面板停在关闭状态 | 标准 `drm_atomic_helper_suspend/resume` |
| 43 个无认证 ioctl | 主线没有这些 vendor ioctl（PQ/AAL/C3D/寄存器） |
| doze/AOD 路径绕过 DRM 直接关面板 | 主线没有 doze 概念，blank 走标准路径 |
| CMDQ wakelock 卡住挂起 | 主线 idle 路径不同（但仍需 `mtk-cmdq` 支持） |

代价：失去 vendor 的 doze/AOD/PQ/mml/CMDQ 深度集成（我们不需要），
以及需要重新验证 touch/bt 的 blank notifier（那部分我们已经用标准
`drm_panel` + notifier 处理了）。

### 13.5 如果以后真要做，先做这个 boot 检查

**关键问题：这块屏能不能跑非 DSC 的 video mode？**

很多 LCM 同时支持 DSC 和非 DSC（DSC 只是省带宽）。如果支持：

1. 先在 v2 里把面板切到非 DSC 模式验证（改 `DSC_ENABLE 0` + 调整 timing）
2. 若 1080x2400@60 非 DSC 能亮，主线 `mtk_dsi` 就够用 → 迁移可行性大幅提升
3. 然后按 面板 → DSI → mmsys/OVL → mutex/RDMA 的顺序逐个上

这一步是**整个迁移的可行性判据**，而且成本很低（一次开机验证）。
在确认之前，不建议投入迁移。

### 13.6 建议的路线

1. **现在**：用 v130（v2 + 审计修复）。日常使用已经没有已知的花屏路径。
2. **短期**：观察 `dmesg | grep -c underflow` 和 `underrun` 是否保持 0；
   v130 的 underrun 恢复会在出错时自愈（`recovering crtc` 日志）。
3. **中期（可选）**：验证面板非 DSC 模式 → 决定要不要启动主线迁移。
4. **长期（可选）**：主线迁移，按 §13.5 的顺序。

---

## 14. v130 验证（2026-10-30，实测）

镜像：`out-scp-v130-rootfs/boot-stockdt.img`
`md5 3a22ac3ccbe084f0861ad9238a85b31f`，内核 `#147`。

### 14.1 系统健康（刷机后）

| 项 | 值 |
| --- | --- |
| 桌面 | gnome-shell ×2，会话 `kily seat0 tty2` |
| 显示 | `card1-DSI-1 = connected / enabled` |
| `disp_sel` | **546 MHz** |
| `underflow` / `buffer underrun` / `layer_info is null` | 0 / 0 / 0 |
| 传感器服务 | `chopin-scp` / `chopin-iio-trigger` / `chopin-sensorproxy` 全 active |
| 朝向 | `(<'normal'>,)` |

（注：验证前执行过 `dmesg -C`，所以计数是清空之后的值。）

### 14.2 #1 ioctl 加固：**行为验证通过**

用一个只读的 `MTK_READ_REG` 测试程序（`_IOWR('d', 0x40+0x28, struct DISP_READ_REG)`）：

```
kily（video 组、非 root、非 DRM master）
  → ioctl rc=-1 errno=13 (Permission denied)
  → dmesg 里驱动日志条数 = 0        ← 根本没到驱动

root
  → 仍然放行
```

**一个重要的细节**：root 测试一开始"通过了"，原因不是补丁无效，而是
**root 有 `CAP_SYS_ADMIN`，open 时会被 DRM 设为 master 并标记 authenticated**
（`drm_ioctl_permit()` 的语义就是"除 root/master/render 客户端外都要求认证"）。
所以正确的验证对象是**非特权用户**——那正是威胁模型。

修复前的对照：同一个程序以 root 运行时驱动被调用并打印
`[DISP][E]reg read, addr invalid, pa:0x0`，证明这条路径确实通到驱动。

### 14.3 其余修复的验证方式

| # | 修复 | 验证 |
| --- | --- | --- |
| 1 | ioctl 认证 | ✅ **行为验证**（见 14.2） |
| 2 | `layer_num` 上界 16 | 代码审查（需 master 才能触发，不专门制造） |
| 5 | underrun 自动恢复 | 符号存在（`mtk_dsi_schedule_underrun_recover`），**未主动触发** underrun |
| 7 | doze 用新状态 | 代码审查（日志降为 debug，正常运行不再刷 `connector has no crtc`） |
| 12 | `snprintf` | 编译通过 |

### 14.4 为什么没有主动测试 #5

触发 DSI underrun 需要人为制造显示链路错误，而在这块已经受过伤的 LCD 上
**任何一次错误帧都可能加深图像粘滞**。因此 #5 只做了代码级验证：

* 恢复例程 `mtk_disp_recover_all()` → `mtk_drm_esd_recover()` 是驱动原有的
  ESD 恢复路径，逻辑成熟（面板关 → CRTC 关 → CRTC 开 → 面板开）
* 冷却 2 秒，避免瞬时带宽抖动引起闪烁
* 只有在真的出现 `buffer underrun` 时才会执行

如果将来日常使用中出现 `dmesg | grep "recovering crtc"`，就说明自愈机制被触发过，
届时再评估效果。
