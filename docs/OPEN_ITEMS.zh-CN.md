# 现状与后续

这块板已经完成 Vivado 2026.1 干净构建、JTAG 配置、PCIe 枚举、XDMA 驱动
加载、双通道 DMA 和完整 4 GiB DDR3 分块校验。下面列的是我接下来还想补的
实验，以及这次调试里已经解决的问题。

## 还可以继续做什么

| 方向 | 当前进度与下一步 |
|---|---|
| W26 | 主板功能还没确认。当前设计不使用它，保持 `Pullnone` 和外部高阻；后续可以继续追主板网络和控制时序 |
| R24 / T20 | 外接负载和方向还没有实板证据，当前顶层和 XDC 均未使用；后续可从主板网络继续测量 |
| J1–J4 / IO 扩展板 | 不在 XDMA 数据通路里；后续可以单独做 GPIO、板型识别和外设实验 |
| PCIe 链路 | FPGA 配置为 Gen2 ×8，当前 M.2 转接只接出 ×4；可以换原生 PCIe 主机继续测链路宽度和吞吐 |
| 长时间稳定性 | 完整 4 GiB 数据比较已经通过；还可以补数小时循环、温度、功耗、AER 和掉电重枚举 |
| XDMA event / MSI | 本轮记录到 IRQ 增量 1188，设计使用单个 MSI vector；event 节点和用户中断延迟还没测 |
| Windows DMA | Windows 已完成 Vivado、JTAG 和枚举；拿到匹配的签名驱动后可以补 H2C/C2H 测试 |
| 其他 Linux 环境 | 当前实测为 x86-64 Ubuntu 24.04.5、内核 `7.0.0-31-generic`；可以继续验证其他发行版和内核 |
| Build ID | 可以加入一个 AXI-Lite build-ID 寄存器，让 Linux 直接读取当前 FPGA 映像身份 |
| 自动配置 | 当前通过 JTAG 写易失 SRAM；后续可以研究 configuration flash 和上电自动配置 |
| Vivado BASIC | 本次干净构建使用 Enterprise 评估许可；可以再用免费的 BASIC 档位重跑一次 |

## 这次已经踩完的坑

| 问题 | 最后的处理方式 |
|---|---|
| Linux 7.0 构建失败 | 清理 vendor Makefile 的 CRLF，把 `EXTRA_CFLAGS` 改成可移植的 `ccflags-y` include path，并移除硬编码内核路径 |
| Secure Boot | 生成并注册本地 MOK，对 `xdma.ko` 签名后由当前内核成功加载 |
| 单次 1 GiB 请求失败 | 改成 64 MiB 分块；前 1 GiB 和完整 4 GiB 均已逐块写入、回读和比较 |
| XDMA 日志误报 | 过滤器不再把正常的 `timeout: h2c ... c2h ...` 参数行当作错误，真实 timeout、AER、页分配和存储错误仍会失败 |
| 精确映像对应关系 | 干净构建、JTAG 记录和实机回归使用同一个 bitstream SHA-256 |
| 测试结束清理 | cleanup 脚本核对目标 BDF、模块和打开的设备节点后卸载驱动 |
| FPGA 工程依赖 | `build.tcl`、BD 生成器、XDC 和 MIG 配置都已放进仓库，可以从源码重新生成工程 |

更完整的实验数值见[实测结果](VALIDATED_RESULTS.zh-CN.md)，接下来可玩的方向见
[后续实验](NEXT_EXPERIMENTS.zh-CN.md)。
