# Documentation map

| Document | Purpose |
|---|---|
| [硬件连接](HARDWARE_SETUP.zh-CN.md) | 供电、JTAG、PCIe、上电顺序与接线图要求 |
| [架构](ARCHITECTURE.zh-CN.md) | 仓库内 FPGA 构建输入及 XDMA、AXI、DDR3 数据路径 |
| [实测结果](VALIDATED_RESULTS.zh-CN.md) | 已证明的结论、当前映像回归状态和证据边界 |
| [待办与边界](OPEN_ITEMS.zh-CN.md) | 发布阻塞项、非阻塞限制和已解决项 |
| [Secure Boot](SECURE_BOOT.zh-CN.md) | MOK 创建、注册、签名与验证 |
| [精确映像一次性回归](EXACT_IMAGE_REGRESSION.zh-CN.md) | 用一个 Ubuntu 会话完成精确 bitstream 的发布验收、失败留证和清理 |
| [Windows 与 WSL](WINDOWS_WSL.zh-CN.md) | 为什么数据面使用原生 Ubuntu |
| [故障排查](TROUBLESHOOTING.zh-CN.md) | 按 FPGA、枚举、构建、加载和 DMA 分层定位 |
| [踩坑记录](LESSONS_LEARNED.zh-CN.md) | 本次联调遇到的问题与复刻建议 |
| [后续实验](NEXT_EXPERIMENTS.zh-CN.md) | 映像回归、链路、并发、稳定性和自定义逻辑方向 |

实验摘要位于 [`evidence/`](../evidence/README.md)。完整 FPGA 生成、构建和
SRAM 下载方法位于 [`fpga/`](../fpga/README.md)。
