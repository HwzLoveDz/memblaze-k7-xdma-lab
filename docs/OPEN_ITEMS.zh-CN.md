# 待办、限制与已解决项

本页只记录当前仓库的真实状态。构建成功、实机下载成功和 DMA 数据通过是
不同结论；任何一项都不能替代另一项。

## 已公开的硬件记录与剩余边界

硬件拓扑和三张脱敏照片已经放入 `docs/images/`。本次发布采用“固定照片所示
实物组合，同时公开未知项”的边界，不把缺少商品铭牌或额外电气测量写成已经
验证的能力。

| 项目 | 已记录事实 | 仍未覆盖 |
|---|---|---|
| 接线拓扑 | `docs/images/wiring-overview.svg` 明确 PCIe、M.2 3.3 V、PD 诱骗 12 V、return/GND、JTAG、J1–J4/W26 和实际重启流程 | JTAG 逐针表、辅助 12 V 连接器逐针/极性定义 |
| 实物组合 | 器材、调试和运行照片已脱敏并去除 EXIF；只验收照片所示实物 | 主板/转接板 PCB 修订、UGREEN 盒型号/桥芯片、线缆认证、DDR 顶标等无法从照片可靠确认的料号 |
| 供电来源 | 12 V 来自独立 USB-C PD 电源和本次设定为 12 V 的诱骗模块；3.3 V 来自雷电盒 M.2 插槽；两条供电轨在板上供电分配中完全隔离且不会回灌，高速 Bank 电压由 PCIe 输入侧决定 | 辅助接口逐针定义、PD/线束额定电流及启动/稳态电流没有公开记录；仓库不据此允许热插拔 |
| 支持范围 | Vivado 2026.1 干净构建和同一 bitstream 的完整实机回归通过 | 其他外观相近主板和任意同类转接链路不得直接套用 pin map |

用户已明确：不要求第二位使用者或另一台干净 Ubuntu 重复复演。本机实板已经
完成上述精确映像回归。

## 已知但不阻塞基础 XDMA

| 项目 | 已知边界 |
|---|---|
| W26 | 功能未知；不作为顶层端口，配置后使用 `Pullnone`，外部保持高阻观察，不作为 XDMA 输出 |
| R24/T20 | 外接负载和方向尚未获得实板证据；当前顶层和 XDC 均不使用这两个封装脚 |
| J1–J4 与 IO 扩展板 | 不属于 XDMA 数据通路，当前 FPGA 设计不驱动这些外部连接器；扩展板 CAD、连接器全量定义和普通 GPIO 用法不在本次仓库验收范围内 |
| OEM 原始资料 | 原主板没有公开的厂家原理图和 pin map；本仓库只对最终 BOM/接线图锁定的实测硬件修订负责 |
| PCIe BAR 资源 | 设计参数中 generic PF0 BAR0 为 128 KiB，XDMA configuration aperture 为 64 KiB；每个确切映像仍需用 `lspci -vv` 保存主机实际分配的 BAR 资源 |
| PCIe 链路能力 | FPGA 端配置为 Gen2 ×8；当前 M.2 转接路径最多只接出 ×4，既有 ASMedia 上游还报告过更窄瓶颈，不能据此宣称 ×8 或峰值带宽 |
| 完整 4 GiB 覆盖 | 已用 64 × 64 MiB 完成全部 4,294,967,296 字节的写入、回读和比较；64/64 块一致。它仍不是长时间老化测试 |
| 单次 1 GiB | 历史 C2H 以 137 结束且没有 compare；公开脚本把单请求限制为 64 MiB，`16 × 64 MiB` 已覆盖前 1 GiB |
| 端到端吞吐 | 已记录完整 4 GiB 墙钟 H2C/C2H `641.454/624.475 MiB/s` 和双通道 `770.408/794.334 MiB/s`；拓扑字段与工具计时仍不自洽，因此不把这些数值宣称为物理链路峰值 |
| 双通道并发 | channel 0/1 各 64 MiB 同时往返并比较通过；尚未做长时间并发压力和错误恢复注入 |
| 中断与 event | 本轮记录 XDMA IRQ 增量 1188；设计启用 MSI、只有 1 个 MSI vector，MSI-X 关闭。尚未验证 event 节点功能和用户中断延迟 |
| 长期稳定性 | 尚未完成数小时循环、温度、功耗、AER 和掉电循环 |
| Windows DMA | Windows 已用于 Vivado/JTAG 和枚举；XDMA H2C/C2H 数据闭环未验证，仓库不包含 AMD Windows 驱动二进制或受限源码，公开数据面仍以原生 Linux 为准 |
| 跨环境兼容 | 既有驱动实测环境为 x86-64 Ubuntu 24.04.5、内核 `7.0.0-31-generic`；其他发行版和内核需现场构建验证 |
| Vivado 许可证层级 | AMD 当前资料把 7 Series 列入免费 BASIC，并说明 XDMA 无额外 IP 费用；本仓库的精确干净构建只在 Enterprise 评估许可证下执行过，BASIC 尚未本机重跑 |
| 映像身份自动检查 | 当前没有独立 AXI-Lite build-ID 寄存器；Linux 写 DDR 前只能由操作者核对构建、JTAG 和实机证据中的 bitstream SHA-256 |
| FPGA 配置方式 | 只提供 JTAG 写易失 SRAM；未验证 configuration flash、自动上电配置或无 Vivado 的预构建映像流程，完全断电后需要重新配置 |
| 自动化覆盖 | GitHub Actions 跑仓库结构、哈希、全部 Shell 语法及 kernel-log、重启参数、错误过滤三项运行时合约；Vivado、JTAG 和实机 DMA 仍需本地工具与硬件 |
| 第三方条款 | XDMA 驱动快照按其 BSD 条款标注；MIG `.prj` 明确受适用 AMD Vivado/IP 条款约束，仓库声明不是对所有地区和使用场景的法律结论 |
| Vivado 非阻断报告项 | 实现 DRC 保留 `PDCN-1569`、`REQP-1709`、`RTSTAT-10` Warning 各 1 条，Error 为 0；methodology 报告有 `LUTAR-1` Warning 3 条、`PDRC-190` Warning 12 条、`XDCB-5` Warning 1 条、`REQP-1959` Advisory 64 条，Related violations 均为 none。它们来自生成的 MIG/XDMA/AXI IP，不等于 DRC Error 或 timing failure；发布证据保留精确计数以防后续漂移 |

这些事项适合后续实验，不需要为了发布基础 Linux XDMA 闭环而伪装成已经完成。

## 已解决

| 项目 | 现有证据 |
|---|---|
| 主机侧依赖固定 | XDMA driver 源码归档、源码 manifest 和 Kbuild 补丁随仓库提供并校验 SHA-256 |
| Linux 分层流程 | 枚举、构建、Secure Boot 检查、加载、DMA 和清理分别执行并分别给出结论 |
| Linux 7.0 构建问题 | CRLF 只在工作副本标准化，`EXTRA_CFLAGS` 改为可移植 `ccflags-y` include path，硬编码内核路径已移除 |
| Secure Boot | 已在保持 Enabled 的条件下用 MOK 签名并成功加载模块；脚本不依赖单一 `mokutil` 返回码 |
| 大请求规避 | 不再进行单次 1 GiB 请求；扩展流程按 64 MiB 分块并在每块回读比较 |
| 精确映像实机回归 | 干净构建、JTAG 和实机使用同一 bitstream SHA-256；枚举、BAR、Secure Boot/XDMA、基础/并发 DMA、完整 4 GiB 和清理均通过 |
| 最终日志假阳性 | 原始总控因 XDMA 的正常 `timeout: h2c ... c2h ...` 参数行返回 1；修正过滤器后真实日志重放为 0 条，真实错误样例仍会判失败 |
| 清理边界 | ownership marker、目标 BDF、模块哈希和打开的设备节点均检查后才卸载 |
| MIG 版本控制边界 | 按 AMD UG949 2026.1 对 7-series memory IP 的版本控制要求保留 `.prj`；它不是项目 MIT 原创文件，使用受适用 AMD Vivado/IP 条款约束 |
| 发布证据门 | 严格 validator 要求固定名称的新 clean-build 与 exact-image 实机摘要，校验文件 SHA-256、逐项 PASS 标记以及两边完全相同的 bitstream SHA-256；只改 manifest 不能放行 |
| FPGA 构建输入 | `build.tcl`、工程/BD 生成器、XDC、MIG `.prj` 和 SRAM-only JTAG 脚本均已落盘，普通 validator 通过结构化静态检查 |
| DDR3 x64 板级闭环 | MIG 配置的 DQ/DM/DQS 索引集合、PAD 唯一性及与 board XDC 的管脚冲突由 validator 检查；干净构建和确切映像完整 4 GiB 实机回归均已通过 |
