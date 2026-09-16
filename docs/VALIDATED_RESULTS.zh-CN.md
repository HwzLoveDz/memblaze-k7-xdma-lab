# 2026-09-16 精确映像实机验证结果

## 结论

仓库内 Vivado 2026.1 生成流已经完成干净构建，生成 bitstream 的 SHA-256 为：

```text
287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5
```

同一文件随后通过 JTAG 写入 XC7K325T 易失 SRAM，并在保持 PD 诱骗 12 V 与
M.2 插槽 3.3 V 两路供电的情况下进入 Ubuntu。RC4 实机完成 PCIe 枚举、XDMA
全新构建/签名/加载、基础
DMA、双通道 DMA、`alias-4g`、`chunked-1g`、完整 4 GiB 分块数据比较、
PCIe/AER 检查和清理，原生返回 `FINAL_EXPERIMENT_RC=0`。构建、JTAG 和实机
证据中的 bitstream 哈希完全一致。

固定名脱敏证据为
[`validated_repository_exact_image_physical_regression_sanitized.log`](../evidence/validated_repository_exact_image_physical_regression_sanitized.log)。

## RC4 证据完整性

返回的精确证据归档和 transport 归档均与各自 SHA-256 sidecar 一致。精确
归档内的 `evidence_files.sha256` 含 100 条唯一记录，逐项校验全部通过；最终
`severe_kernel_messages.txt` 为空。严重消息过滤器的运行时合约在加载 DMA 前
执行并通过，最终扫描在驱动清理后执行，因此也覆盖卸载阶段。

上一版规则曾把驱动加载时的正常参数信息误判为失败：

```text
xdma:xdma_mod_init: desc_blen_max: 0xfffffff/268435455, timeout: h2c 10 c2h 10 sec.
```

该行只表示 H2C/C2H 超时参数均设为 10 秒。RC4 的过滤器只排除这条格式固定的
参数行，真正的 `timed out`、`timeout`、`failed`、`error`、AER、页分配和
存储错误仍会使实验失败。本次无需人工裁定或事后改写结果。

## 构建与实机条件

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
| 存储边界 | Windows NVMe、EFI、BitLocker 分区均未挂载；无 swap |

干净构建同时得到 DRC Error 0、setup WNS `+0.038 ns`、hold WHS
`+0.014 ns`、10 条 bus-skew 约束全部通过。构建证据见
[`validated_repository_clean_build_vivado_2026_1_sanitized.log`](../evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log)。

## 分层结果

这些门彼此独立，不能互相代替：

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

历史上的单次 1 GiB 请求仍未验证：其 C2H 以 137 结束且没有 compare 结果。
它不影响本次分块完整覆盖结论，也不能被写成“单次 1 GiB 已通过”。

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
624.475 MiB/s。它们是用户态工具/请求计时，不直接等于 PCIe 链路净吞吐。

从精确工作流 run ID 到清理结果目录约 64.53 秒；其中 XDMA 从加载到卸载约
55.07 秒。日志同时证明旧构建树先被移走，驱动和用户态工具均在本轮重新构建，
没有复用旧 DMA 结果。所有阶段合计每个方向实际传输 5,644,488,704 字节，
双向合计约 10.51 GiB。

同一轮 `lspci` 报告 endpoint 能力为 Gen2 ×8，当前为 Gen2 ×4；上游
ASMedia/Thunderbolt 字段中仍出现 2.5 GT/s ×1。该字段组合与工具计时不自洽，
所以本仓库保留两组原始含义，不据此宣称峰值 PCIe 性能或桥接器真实瓶颈。

## 仍未覆盖的范围

- 没有验证单请求 1 GiB；
- 没有完成数小时温度、功耗、AER、掉电与反复重枚举循环；
- 没有完成 Windows XDMA 数据闭环；
- 没有验证 configuration flash 或自动上电配置；完全断电后仍需 JTAG；
- W26 功能未知，不作为顶层端口，配置后保持 `Pullnone` 和外部高阻；
- 本次连接和实物组合见[硬件连接](HARDWARE_SETUP.zh-CN.md)与
  [`wiring-overview.svg`](images/wiring-overview.svg)。12 V 与 3.3 V 供电轨已确认
  在板上供电分配中完全隔离且不会回灌，高速 Bank 电压由 PCIe 输入侧决定；
  电流数据和无法从照片确认的料号仍属于公开已知边界。JTAG 与辅助供电逐针
  接线属于使用者自有硬件的基础适配，不作为仓库交付项。

完整未脱敏归档只保存在本地分析目录，不进入公开仓库；公开证据不包含个人
路径、USB/JTAG 序列号、MOK 标识、私钥或 DMA payload。
