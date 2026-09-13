# 数据路径与工程边界

## 运行时数据路径

```mermaid
flowchart LR
    U[Linux 用户态工具] -->|read/write| N[/dev/xdma0_h2c_*<br/>/dev/xdma0_c2h_*]
    N --> K[xdma.ko]
    K --> P[PCIe / Thunderbolt 桥接路径]
    P --> E[XDMA Endpoint]
    E --> C[AXI Clock Converter]
    C --> I[AXI Interconnect]
    I --> M[MIG 7 Series]
    M --> D[4 GiB DDR3]
```

主机写入 H2C 后，数据经 XDMA 的 AXI Memory Mapped 接口进入 MIG；C2H
走相反方向。验证重点为：

1. 仓库源码能否从空构建目录生成 FPGA 工程并通过实现检查；
2. 生成的确切 bitstream 是否写入 FPGA 易失 SRAM；
3. 主机是否枚举到预期 PCIe endpoint；
4. 内核模块是否绑定同一个 endpoint，并创建设备节点；
5. 写入、读回和 `cmp` 是否一致；
6. 高地址是否发生截断、回卷或镜像；
7. 测试前后是否出现新的 AER、XDMA、timeout 或 fatal 内核消息。

这些是相互独立的证据门。某一层通过不能替代后一层。

## 仓库内 FPGA 设计

完整构建输入随仓库分发：

- `fpga/build.tcl`：创建工程、生成输出、综合实现、报告和可选 bitstream；
- `fpga/create_project.tcl`：创建工程并加入仓库源码；
- `fpga/bd/create_design.tcl`：建立 XDMA、AXI 和 MIG 数据路径；
- `fpga/constraints/board.xdc`：PCIe、DDR3、板载时钟及相关时序约束；
- `fpga/mig/memblaze_ddr3.prj`：64-bit DDR3 MIG 配置；
- `fpga/program_sram.tcl`：只对匹配的 XC7K325T 执行易失 SRAM 下载。

目标器件为 `xc7k325tffg900-2`，目标 AXI DDR 地址空间为
`0x00000000–0xffffffff`，顶层为 `memblaze_k7_xdma_wrapper`。Vivado
的缓存、生成 IP、DCP、网表和 bitstream 是构建产物，不作为源码提交。

generic PF0 BAR0 参数为 128 KiB，XDMA core 内部的 configuration aperture
参数为 64 KiB，这两个尺寸不能混写。主机对确切 bitstream 实际分配和报告的
BAR 资源必须在每次实机回归中用 `lspci -vv` 单独保存。

仓库内生成流从 `fpga/build.tcl` 启动。当前发布前仍需把它生成的确切
bitstream 写入本机实板，再重复 JTAG、枚举、驱动、基础 DMA、
`alias-4g`、`chunked-1g` 和清理门。完成前，既有实验只能证明此前
实验路径，不能替代新映像验收。

## 外部 IO 边界

J1–J4 是原存储子板接口的 IO 引出。本次 XDMA 示例不依赖存储子板或 IO
扩展板。实测相关 FPGA Bank 的 VCCO/IO 高电平为 1.8 V；旧
`LVCMOS33` 约束不能直接复用。W26 功能尚未最终确认，不作为顶层端口或
XDMA 设计输出，外部保持高阻观察。Vivado 2026.1 对未使用配置引脚使用合法值
`BITSTREAM.CONFIG.UNUSEDPIN Pullnone`，表示不启用内部弱上拉或弱下拉。
