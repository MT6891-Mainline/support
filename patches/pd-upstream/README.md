# 上游补丁：tcpci_mt6360 的 PD 修复

两个补丁修的是**主线上游 bug**（不是 chopin 移植引入的），
任何使用 MT6360 TCPC 的平台（platform probe 路径）都受影响。

## 补丁

| 文件 | 作用 |
| --- | --- |
| `0001-...-match-vendor-cc-setup.patch` | 补 `TCPC_POWER_CTRL = 0x70`（关 bleed discharge）和 LOOK4CONNECTION 告警 |
| `0002-...-unmask-the-TCPC-alerts.patch` | **核心 bug**：platform probe 从不 unmask 告警，掩码停在 0 |

## 症状（供 commit message 参考）

```
TCPC_ALERT      (0x10) = 0x01   ← 告警挂着
TCPC_ALERT_MASK (0x12) = 0x00   ← 但全屏蔽
/proc/interrupts: mt6360-tcpc → 0 次中断
power_operation_mode = default, VBUS 恒为 5V
```

CC 检测（轮询）正常，所以 `power_role=sink` 看起来没问题，容易误判为
"充电器不支持 PD"。

## 提交前的 TODO

1. **补 `Fixes:` 标签**。本树没有引入该驱动的上游提交（baseline 是压缩的），
   请在真实 upstream 树上查：

   ```sh
   git log --oneline --reverse -- drivers/usb/typec/tcpm/tcpci_mt6360.c | head -1
   ```

   然后加到 `Signed-off-by:` 之前。

2. 确认收件人：

   ```sh
   ./scripts/get_maintainer.pl --no-git --no-roles \
       drivers/usb/typec/tcpm/tcpci_mt6360.c
   ```

   通常是 Heikki Krogerus、Greg Kroah-Hartman、linux-usb、linux-kernel。

3. 发送：

   ```sh
   git send-email --to=... --cc=... 0001-*.patch 0002-*.patch
   ```

## 验证记录

在 Xiaomi Redmi Note 10 Pro（MT6893, chopin）上实测：

* 修复前：PD 充电器插上恒为 5V，`power_operation_mode=default`，
  TCPC 中断计数 0
* 修复后：协商到 **12V/2.25A**，电池充电 **3.76A**，
  19%→27% 仅用 4 分钟（2%/分钟），电池温度 33→36°C
