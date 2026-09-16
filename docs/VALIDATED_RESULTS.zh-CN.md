# 这次实机测试跑到了什么程度

## 结论

我用仓库里的 Vivado 2026.1 生成流做了一次干净构建，得到的 bitstream
SHA-256 为：

```text
287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5
```

我把同一个文件通过 JTAG 写入 XC7K325T 易失 SRAM，再保持 12 V 和 3.3 V
供电重启到 Ubuntu。最终测试跑完 PCIe 枚举、XDMA 构建/签名/加载、基础 DMA、
双通道 DMA、`alias-4g`、`chunked-1g`、完整 4 GiB 分块比较、PCIe/AER 检查
和清理，返回 `FINAL_EXPERIMENT_RC=0`。构建、JTAG 和实机使用的是同一个
bitstream 哈希。

固定名脱敏证据为
[`validated_repository_exact_image_physical_regression_sanitized.log`](../evidence/validated_repository_exact_image_physical_regression_sanitized.log)。

## 这次用的环境

| 项目 | 实测条件 |
|---|---|
| 主机 | ASUS ROG Flow Z13 |
| 系统 | Ubuntu 24.04.5 LTS Persistent Live USB |
| 内核 | `7.0.0-31-generic` |
| FPGA | Kintex-7 XC7K325T，JTAG 写易失 SRAM |
| PCIe ID | `10ee:7024`，Subsystem `10ee:0007` |
| 活动 BAR0 | 64 KiB，由本轮 `lspci -vv` 与 sysfs resource 计算得到 |
| XDMA 驱动 | 2025.2.0，固定源码提交 `b8466090` |
| Secure Boot | Enabled，已注册 MOK 签名的模块被内核接受 |

干净构建同时得到 DRC Error 0、setup WNS `+0.038 ns`、hold WHS
`+0.014 ns`、10 条 bus-skew 约束全部通过。构建证据见
[`validated_repository_clean_build_vivado_2026_1_sanitized.log`](../evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log)。

## 实际测试结果

| 层级 | 结果 |
|---|---|
| JTAG 映像身份 | PASS；bitstream 哈希与干净构建一致 |
| PCIe 枚举 | PASS；唯一 `10ee:7024/10ee:0007`，BDF `0000:09:00.0` |
| 驱动构建与签名 | PASS；模块匹配当前内核并被 Secure Boot 接受 |
| 驱动绑定 | PASS；control、H2C0/1、C2H0/1 节点出现 |
| 基础 DMA | PASS；4 KiB、两组 1 MiB 和两通道独立 64 MiB 均一致 |
| 高地址/前 1 GiB | PASS；`alias-4g` 与 `chunked-1g` 均一致 |
| 双通道并发 | PASS；channel 0/1 各 64 MiB 同时往返并分别比较 |
| 完整 4 GiB | PASS；64 × 64 MiB，64 条 WRITE、64 条 VERIFY、0 mismatch |
| 内核与 PCIe | PASS；路径摘要稳定，AER 前后稳定，IRQ 增量 1188，清理后严重消息 0 |
| 清理 | PASS；`CLEANUP_RC=0`，模块和 `/dev/xdma*` 节点消失 |

## DMA 覆盖范围

基础用例包括：

- 4 KiB，channel 0，地址 `0x00000000`；
- 1 MiB，channel 0，地址 `0x10000000`；
- 1 MiB，channel 1，地址 `0x20000000`；
- 64 MiB，channel 0，地址 `0x04000000`；
- 64 MiB，channel 1，地址 `0x44000000`。

`alias-4g` 在 0、1、2、3 GiB 和 `0xFFF00000` 写入五个不同 1 MiB 图样，
全部写完后逐一回读，用于排除采样窗口上的明显地址回卷和镜像。

`chunked-1g` 用 16 × 64 MiB 覆盖前 1 GiB。最终完整测试用 64 × 64 MiB
覆盖地址 `0x00000000` 至 `0xFFFFFFFF` 对应的全部 4,294,967,296 字节；
每块先记录期望 SHA-256，再回读并比较，64/64 一致。单个 DMA 请求始终不超过
64 MiB。

我也试过一次性发起 1 GiB 请求，C2H 最后以 137 结束，没有进入 compare。
所以正式脚本改用 64 MiB 分块；前 1 GiB 和完整 4 GiB 都已经用分块方式通过。

## 双通道、链路与计时

四个控制引擎标识均正确：

```text
H2C0=0x1fc00006
H2C1=0x1fc00106
C2H0=0x1fc10006
C2H1=0x1fc10106
```

双通道各 64 MiB 并发时，工具墙钟汇总值为 H2C 770.408 MiB/s、C2H
794.334 MiB/s。完整 4 GiB 分块墙钟值为 H2C 641.454 MiB/s、C2H
624.475 MiB/s。这些数字来自用户态工具和请求计时。

整套流程从创建 run ID 到写出清理结果约 64.53 秒，其中 XDMA 从加载到卸载约
55.07 秒。脚本先移走旧构建树，再重新构建驱动和用户态工具。所有阶段合计
每个方向实际传输 5,644,488,704 字节，
双向合计约 10.51 GiB。

同一轮 `lspci` 报告 endpoint 能力为 Gen2 ×8，当前为 Gen2 ×4；上游
ASMedia/Thunderbolt 字段中仍出现 2.5 GT/s ×1。两组信息并不自洽，我把原始
读数都保留了。链路带宽、Windows DMA、自动配置和长期稳定性实验统一列在
[`NEXT_EXPERIMENTS.zh-CN.md`](NEXT_EXPERIMENTS.zh-CN.md)。
