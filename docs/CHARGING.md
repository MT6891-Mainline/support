# chopin 充电与电量（主线下）

## 1. 电量计：BQ27Z561 在 i2c0，必须用 100 kHz

**症状**：驱动绑定，但 `capacity=65535`、`voltage_now=65535000`、`health=Dead`。

**误判过程**（值得记住）：

| 观测 | 错误推断 |
| --- | --- |
| 所有寄存器读 0xFF | "芯片坏了 / 需要厂商 unseal 序列" |
| 双字节写 NAK | 同上 |
| 地址能 ACK | "芯片活着但寄存器不可访问" |

**真相**：做同总线对照实验才看清——

```
i2c5 @0x34 (MT6360 PMU)  →  0x53 0x18   ✅
i2c0 @0x35 (xmusb350)    →  0xff 0xff   ❌
i2c0 @0x55 (BQ27Z561)    →  0xff 0xff   ❌
```

**i2c0 上两个不同芯片都读不出来**，问题在总线。把 `clock-frequency` 从
400 kHz 降到 **100 kHz** 后立刻正常：

```
0x08 电压 = 0x0e82 = 3714 mV
0x2c SOC  = 0x000c = 12 %
0x0c 电流 = 0x0059 = 89 mA
```

厂商 DTS 也写 400 kHz，说明这是 **主线 `i2c-mt65xx` 的时序计算差异**，不是板级限制。
没继续追 400 kHz 的原因：电量计 10 秒读一次，100 kHz 完全够用。

### 教训
**遇到"I2C 设备读全 0xFF"时，第一件事是拿同总线上的另一个设备做对照**，
而不是去猜设备状态。

## 2. 电量数值

| 来源 | 值 | 精度 |
| --- | --- | --- |
| TI 库仑计（主线驱动） | SOC 寄存器 | **±1%** |
| 安卓 recovery 的 UI SOC | 平滑/补偿后的值 | 比原始值高约 4% |
| 早期 ADC 电压估算（已弃用） | 分段曲线 | ±15%，实测高估一倍 |

电池信息（实测）：

```
cycle_count = 3         循环次数
charge_full = 4950 mAh  学习容量（设计 5000 mAh，健康度 99%）
temp        = 32.4 °C
```

## 3. 充电电流

**问题**：主线下 MT6360 用 SDP 默认值，输入 500 mA、充电 500 mA。
手机自身耗电约 400 mA，于是只有 **85 mA** 进电池——1.7%/小时，看起来"充不进电"。

**实测**：

| 输入限流 | VBUS | 电池电流 |
| --- | --- | --- |
| 500 mA（默认） | 4981 mV | 84 mA |
| 900 mA | 4881 mV | **528 mA** |
| 1500 mA | 4737 mV | 1157 mA |
| 2000 mA | 4662 mV | 1420 mA |

**固化为服务** `chopin-charge-tune.service`：

* `usb_type` 方括号里是**当前**类型（`Unknown [SDP] DCP CDP`），按它取值
* SDP（普通 PC 口）→ 输入 900 mA，电池 1500 mA
* DCP/CDP（专用充电器）→ 输入 2000 mA
* 可用 `/etc/chopin-charge-limit` 覆盖输入限流
* udev 规则在插拔/电源类型变化时重新应用

**验证**：13% → 15%，5 分钟充进 115 mAh（1380 mAh/h）✅

## 4. 相关文件

| 文件 | 作用 |
| --- | --- |
| `port/rootfs-common/chopin-charge-tune.sh` | 设置限流 |
| `port/rootfs-common/chopin-charge-tune.service` | 开机应用 |
| `port/rootfs-common/99-chopin-charge.rules` | 插拔时重新应用 |
| `drivers/power/supply/chopin_adc_battery.c` | 早期 ADC 估算（已禁用，保留备查） |

## 5. PD 快充：两个上游 bug（2026-10-31 打通）

### 5.1 症状

PD 充电器（C-to-C 线）插上后：

```
power_operation_mode = default      ← 没有 PD 合约
VBUS = 4975 mV                      ← 一直 5V
TCPC 中断计数 = 0                    ← 整个 uptime 一次都没触发
```

CC 检测是好的（`power_role=sink`），但 **PD 消息一条都收不到**。

### 5.2 bug 一：TCPC 告警被永久屏蔽

直接读 TCPC 寄存器（i2c5 @0x4e，独立于 PMU 的 0x34）：

```
reg 0x10 (ALERT)      = 0x01   ← 有 CC_STATUS 告警挂着
reg 0x12 (ALERT_MASK) = 0x00   ← 但全部屏蔽
```

主线 `tcpci_i2c_probe()` 末尾会打开掩码：

```c
err = tcpci_write16(chip->tcpci, TCPC_ALERT_MASK, chip->tcpci->alert_mask);
```

但 **MT6360 的 tcpc 是 platform 设备**，走 `mt6360_tcpc_probe()`，
那条路径**没有这一行**；而 `mt6360_tcpc_init()` 又主动把掩码写成 0
（注释"write all alert to masked"，指望上层再打开）。

→ 掩码永远停在 0，TCPC 永不拉低 PD_IRQB。

**这是主线上游 bug，不是移植引入的。**

修复（`mt6360_tcpc_probe()` 末尾）：

```c
u16 mask = TCPC_ALERT_TX_SUCCESS | TCPC_ALERT_TX_FAILED |
           TCPC_ALERT_TX_DISCARDED | TCPC_ALERT_RX_STATUS |
           TCPC_ALERT_RX_HARD_RST | TCPC_ALERT_CC_STATUS;
mt6360_tcpc_write16(regmap, TCPC_ALERT_MASK, mask);
```

### 5.3 bug 二：DTS 只声明 5V PDO

```dts
sink-pdos = <PDO_FIXED(5000, 3000, ...)>;   /* 只有 5V */
op-sink-microwatt = <10000000>;             /* 只声明 10W */
```

即使 PD 通了，TCPM 也只会要 5V。改为：

```dts
op-sink-microwatt = <27000000>;
sink-pdos = <PDO_FIXED(5000, 3000, ...)
             PDO_FIXED(9000, 3000, ...)
             PDO_FIXED(12000, 2250, ...)>;
```

### 5.4 修复后实测

```
TCPC 中断 = 11（之前 0）
power_operation_mode = usb_power_delivery
orientation = normal
VBUS = 11881 mV              ← 12V 合约
ALERT_MASK = 0x7d
```

充电 4 分钟：

| 时间 | SOC | 电流 | 电压 | 温度 |
| --- | --- | --- | --- | --- |
| 0 | 19% | 3770 mA | 3951 mV | 33 °C |
| 4 min | 27% | 3762 mA | 4006 mV | 36 °C |

**2% / 分钟**，19% → 100% 约 1 小时。输入 11.7V × 2A ≈ 23 W，
电池侧约 15 W（差值是手机自身负载 + 开关损耗）。

### 5.5 电流设置

PD 合约下（脚本自动识别）：
* 输入限流 2 A（PDO 允许 2.25 A）
* 充电限流 4 A（0.8C，实测 3.76 A）

温度实测 36 °C，无过热风险。若要更保守，可在
`/etc/chopin-charge-limit` 覆盖输入限流。

### 5.6 未做的部分：33W/67W 充电泵

厂商的 33W+ 走 BQ25970 充电泵（2:1 分压），需要 ~2 万行厂商框架，
见 §4 的评估。当前 23 W 输入已经是 MT6360 单独能达到的上限附近
（受 12V/2.25A PDO 与开关损耗限制），不移植充电泵也能接受。

## 6. 最终实测（2026-10-31，SOC 19% → 52%）

### 6.1 功率

```
VBUS = 11.7 V × 2.0 A   →  输入 23 W
VBAT = 4.02 V × 3.73 A  →  入电池 15 W
差值 ≈ 8 W = 手机自身负载 ~4 W + 开关损耗 ~4 W（效率约 85%）
```

对应厂商口径是 **23W 快充**。

### 6.2 温度曲线（全程 3.75 A 恒流）

| 时间 | 电池温度 | SOC |
| --- | --- | --- |
| 19% 时 | 33 °C | 19% |
| +4 min | 36 °C | 27% |
| +12 min | 40 °C | 40% |
| +20 min | 42 °C | 52% |

**0.17 °C/分钟**，线性平稳。JEITA 的安全线一般是 45 °C，
且 60% 之后进入恒压阶段电流会自动下降，所以峰值不会失控。

### 6.3 用户可调项

| 文件 | 作用 |
| --- | --- |
| `/etc/chopin-charge-limit` | 输入限流（微安） |
| `/etc/chopin-charge-current` | 电池侧充电电流（微安） |

```sh
# 温和充电：约 36 °C、1.5 小时
echo 2500000 > /etc/chopin-charge-current
/usr/local/bin/chopin-charge-tune.sh

# 恢复全速：4 A、约 42 °C、1 小时
rm /etc/chopin-charge-current
/usr/local/bin/chopin-charge-tune.sh
```

### 6.4 为什么不再往上做

| 手段 | 预计增益 | 代价 |
| --- | --- | --- |
| 9 V 合约替代 12 V | +5%（效率） | 一次刷机验证，收益被 4 A 充电限流吃掉 |
| 提高充电限流到 5 A | 0 | 温度会冲到 48 °C+，实际触发降频 |
| **BQ25970 充电泵（33W+）** | +80% | 约 2 万行厂商框架，数周 |

结论：**23W 输入 / 15W 入电池是 MT6360 单独能达到的合理上限**，保留现状。
