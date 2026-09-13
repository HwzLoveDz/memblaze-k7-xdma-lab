# 2026-09-14 实机验证结果

## 如何理解当前证据

仓库内已经包含完整 FPGA Tcl、XDC 和 MIG 输入，可以从空构建目录生成工程。
这个生成流加入仓库后，它产生的确切 bitstream 尚未在本机实板完成回归。

因此这里把两件事分开记录：

- **既有实机基线：** 同一块 Memblaze/Kintex-7 主板和主机路径已经完成
  JTAG、枚举、驱动、DMA、扩展 DDR 测试与清理；
- **仓库新映像验收：** `fpga/build.tcl` 的干净构建已经通过；待用它生成
  的确切 bitstream 重跑实机门，并确认构建哈希与实机使用哈希一致。

完成第二项以前，不能声称仓库当前生成的映像已经获得下面全部实机结果。

## 仓库生成流的干净构建

2026-09-14 在全新构建目录中用 Vivado 2026.1 完成了仓库内生成流：返回
码为 0，器件为 `xc7k325tffg900-2`，顶层为
`memblaze_k7_xdma_wrapper`，DRC Error 为 0，setup WNS 为 0.038 ns，
hold WHS 为 0.014 ns；50 MHz 时钟为 `clk_in1_50M`、周期 20.000 ns。
严格 `check_timing` 的九个必须为零的类别全部为 0，固定允许项计数为
`no_input_delay=9`、`no_output_delay=1`、`pulse_width_clock=8`。Bus skew
共 10 条、违反 0 条、最小余量 3.331 ns。生成 bitstream 的 SHA-256 在
clean-build 证据中单独保存，并将在实机回归中逐字一致复核。

固定名脱敏证据为
[`validated_repository_clean_build_vivado_2026_1_sanitized.log`](../evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log)，
FPGA source-set SHA-256 为
`21ced21f69c2f8265b6e61a31f1cd207b2e67c24a885ba5ff3cbddeae63812c0`，
bitstream SHA-256 为
`287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5`。

完整 methodology 报告同时包含生成 IP 的 `LUTAR-1` Warning 3 条、
`PDRC-190` Warning 12 条、`XDCB-5` Warning 1 条和 `REQP-1959`
Advisory 64 条；这些类别的 Related violations 均为 none。这里保留计数，
不把它们混写成 DRC Error 或 timing failure，也不声称已经消除。

## 既有实机基线条件

| 项目 | 条件 |
|---|---|
| 主机 | ASUS ROG Flow Z13 |
| 系统 | Ubuntu 24.04.5 LTS Persistent Live USB |
| 内核 | `7.0.0-31-generic` |
| FPGA | Kintex-7 XC7K325T |
| PCIe ID | `10ee:7024`，Subsystem `10ee:0007` |
| 既有映像活动 BAR0 | `lspci` 报告 64 KiB，`config_bar`；仅属于该次既有基线 |
| XDMA 驱动 | 2025.2.0，固定源码提交 `b8466090` |
| Secure Boot | Enabled |
| FPGA 配置 | JTAG 写易失 SRAM；没有写 configuration memory |

Windows 内置 NVMe、EFI、BitLocker 和启动项没有被实验脚本修改。DMA
测试写入的是 FPGA 外部 DDR，不是主机磁盘。

## 三个独立通过条件

### 1. PCIe 枚举

`lspci` 找到唯一 `10ee:7024`。这只证明主机看到了 PCIe endpoint，
不能代替驱动、映像身份或数据验证。

### 2. XDMA 驱动

XDMA v2025.2.0 针对运行内核完成构建和 MOK 签名，内核在 Secure Boot
开启状态下接受模块。驱动绑定后出现：

- `/dev/xdma0_control`；
- `/dev/xdma0_h2c_0`、`/dev/xdma0_h2c_1`；
- `/dev/xdma0_c2h_0`、`/dev/xdma0_c2h_1`。

这证明驱动完成加载和绑定，仍不能代替 DMA 数据比较。

### 3. DMA 数据

基础用例全部 H2C、C2H 返回 0，哈希一致且 `cmp=0`：

- 4 KiB，channel 0，地址 `0x00000000`；
- 1 MiB，channel 0，地址 `0x10000000`；
- 1 MiB，channel 1，地址 `0x20000000`；
- 独立 64 MiB，channel 0。

扩展用例：

- `alias-4g`：0、1、2、3 GiB 和 `0xFFF00000` 各写一个不同的 1 MiB
  图样，全部写完后逐一回读，五处均一致；
- `chunked-1g`：前 1 GiB 拆为 16 个 64 MiB 区块，全部写完后逐块
  重新生成期望数据、回读并比较，共 1,073,741,824 字节一致。

两项扩展测试期间，没有新增匹配 XDMA、AER、PCIe、timeout、fatal、
error 或 fault 的内核消息；测试前后 PCIe 配置和拓扑摘要保持一致。

## 单次 1 GiB 负例

历史测试中，一次单请求 1 GiB H2C 返回成功，C2H 最终以 137 结束，没有
产生 compare 结果。这个证据不能判断是 host request/buffer 压力、超时、
驱动、持久化介质写入、DDR 还是其他原因。

因此公开脚本把每个 DMA 请求限制在 64 MiB 以内。随后
`16 × 64 MiB` 的前 1 GiB 完整覆盖通过，说明此前负例本身不能证明 DDR
损坏，也不能声称单次 1 GiB 已经通过。

## PCIe 链路

既有映像的主机侧活动 BAR0 为 64 KiB `config_bar`。仓库新设计的 XDMA
参数同时包含 generic PF0 BAR0 128 KiB 和 XDMA configuration aperture
64 KiB；这两个配置字段不能直接替代主机资源报告。新映像回归必须重新保存
`lspci -vv` 的活动 `Region 0`，并把实测大小写入证据和 manifest。

| 位置 | Capability | 实际状态 |
|---|---|---|
| FPGA endpoint | 5 GT/s ×8 | 5 GT/s ×4，downgraded |
| ASMedia downstream | 16 GT/s ×4 | 5 GT/s ×4 |
| ASMedia upstream | 2.5 GT/s ×1 | 2.5 GT/s ×1 |
| Thunderbolt root port | 2.5 GT/s ×4 | 2.5 GT/s ×4 |

内核根据这组拓扑字段把可用路径带宽估为约 2.000 Gb/s，并指向 ASMedia
上游 `2.5 GT/s ×1` 段。可是另一次 64 MiB 测试中，XDMA 工具报告 H2C
约 597 MB/s、C2H 约 563 MB/s，超过 Gen1 ×1 的理论端到端能力。两组记录
并非同一时刻采集，64 MiB 日志也没有同步拓扑快照。由此只能确认现有证据
不足以给出自洽吞吐结论，不能把其中一组数当作已经证实的端到端性能。

## 发布前确切映像实机回归

对 `fpga/build.tcl` 最终生成的 bitstream 至少完成：

构建和哈希门已经完成。对上述 SHA-256 的同一 bitstream 继续完成：

1. JTAG 写入易失 SRAM，并记录实机使用的同一个 SHA-256；
2. 冷启动或重新枚举后通过唯一 `10ee:7024/10ee:0007` 检查；
3. 保存该次 `lspci -vv` 的活动 BAR 资源；
4. 构建、签名、加载 XDMA；
5. 基础 DMA、`alias-4g`、`chunked-1g`；
6. 检查新内核消息并完成 `CLEANUP_RC=0`。

用户已明确不要求第二台主机或另一位使用者重复复演。

## 证据边界

- 五个高地址哨兵只排除了这些窗口上的明显回卷或镜像；
- 前 1 GiB 得到逐字节覆盖，剩余 3 GiB 没有逐字节扫描；
- 没有完成长时间温度、功耗、AER 或掉电循环测试；
- 没有验证 Windows XDMA 数据闭环；
- 没有完成可解释链路字段与 XDMA 计时矛盾的端到端吞吐基准；
- W26 功能未知，不作为顶层端口；配置后使用 `Pullnone`，外部保持高阻
  观察，不属于 XDMA 数据通路。

对应脱敏日志见 [`evidence/`](../evidence/README.md)，完整待办见
[`OPEN_ITEMS.zh-CN.md`](OPEN_ITEMS.zh-CN.md)。
