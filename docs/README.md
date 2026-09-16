# 文档导航

| 文档 | 内容 |
|---|---|
| [硬件连接](HARDWARE_SETUP.zh-CN.md) | 这次实机使用的供电、JTAG、PCIe 和启动顺序 |
| [架构](ARCHITECTURE.zh-CN.md) | 仓库内 FPGA 构建输入及 XDMA、AXI、DDR3 数据路径 |
| [实测结果](VALIDATED_RESULTS.zh-CN.md) | 这次实机跑过的构建、枚举、DMA 和 DDR3 测试 |
| [现状与后续](OPEN_ITEMS.zh-CN.md) | 还可以继续做什么，以及这次已经踩完的坑 |
| [Secure Boot](SECURE_BOOT.zh-CN.md) | MOK 创建、注册、签名与验证 |
| [精确映像一次性回归](EXACT_IMAGE_REGRESSION.zh-CN.md) | 一次进 Ubuntu 跑完构建、DMA、日志归档和清理 |
| [Windows 与 WSL](WINDOWS_WSL.zh-CN.md) | 为什么数据面使用原生 Ubuntu |
| [故障排查](TROUBLESHOOTING.zh-CN.md) | 按 FPGA、枚举、构建、加载和 DMA 分层定位 |
| [踩坑记录](LESSONS_LEARNED.zh-CN.md) | 本次联调遇到的问题与复刻建议 |
| [后续实验](NEXT_EXPERIMENTS.zh-CN.md) | 映像回归、链路、并发、稳定性和自定义逻辑方向 |

实验摘要位于 [`evidence/`](../evidence/README.md)。完整 FPGA 生成、构建和
SRAM 下载方法位于 [`fpga/`](../fpga/README.md)。
