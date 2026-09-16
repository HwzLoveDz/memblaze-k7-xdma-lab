# 硬件连接

我这次实机测试使用了下面这套连接和供电。

## 连接拓扑

![本次连接拓扑](images/wiring-overview.svg)

数据和电源分成三条路径：

1. `Flow Z13 → Thunderbolt 4 → UGREEN M.2 外接盒 → M.2 M-Key →
   PCIe ×4 转接板 → Memblaze 主板`，承载 PCIe 数据；
2. 雷电/USB4 M.2 盒通过 M.2 插槽向转接板和主板 PCIe 3.3 V 轨供电；
3. 独立 USB-C PD 电源经本次设定并协商到 12 V 的诱骗模块，将 `+12 V` 与
   return/GND 送入转接板辅助电源输入，再由转接板送到主板 PCIe 12 V 输入轨。

这里的 12 V 和 3.3 V 均指主板 PCIe 输入电源轨。

我在 Windows 下通过 JTAG 配置 SRAM，然后保持两路供电重启进入 Ubuntu，
完成枚举和 XDMA 测试。实物电源关系已经确认：12 V
与 3.3 V 两条供电轨在板上供电分配中完全隔离且不会回灌；板上高速 Bank 的
电压由 PCIe 输入侧决定，而不是由辅助 12 V 路径决定。

## 实物照片

<p align="center">
  <img src="images/hardware-parts-overview.jpg" width="900"
       alt="本次实验器材总览">
</p>

从左到右为 Xilinx Platform Cable USB（型号 `DLC9LP`）、带主动散热的
Memblaze/XC7K325T 主板、
板面标有 `PCIE 4.0` 的 M.2 M-Key↔PCIe ×4 插槽转接板、UGREEN M.2 外接盒和
连接线。

<p align="center">
  <img src="images/xdma-debug-session.jpg" width="900"
       alt="原生 Ubuntu 下进行 XDMA 分块回读与比较">
</p>

调试照记录原生 Ubuntu 下的 64 MiB 分块 C2H 回读和 SHA-256 比较过程。最终
PASS、覆盖范围和速度见 [`VALIDATED_RESULTS.zh-CN.md`](VALIDATED_RESULTS.zh-CN.md)
及仓库脱敏日志。

<p align="center">
  <img src="images/hardware-running.jpg" width="900"
       alt="实机通电运行状态">
</p>

运行照记录测试期间的实机通电状态，背景设备的唯一标识已脱敏。

## 实物 BOM

| 项目 | 本次实测组合 |
|---|---|
| 主板 | Memblaze/PBlaze3 系列实物，Kintex-7 `XC7K325T`；设计目标为 `xc7k325tffg900-2` |
| DDR3 | MIG 配置档 `MT41K512M8XX-125`，64-bit 数据、8 组 DM/DQS；完整 4 GiB 数据闭环通过 |
| 主机 | ASUS ROG Flow Z13；原生 Ubuntu 24.04.5 Persistent Live USB |
| 外接盒 | 照片所示 UGREEN M.2 外接盒 |
| 转接板 | 照片所示 M.2 M-Key↔PCIe ×4 插槽转接板，带辅助 12 V 输入 |
| 数据线 | 照片所示主机到外接盒 Type-C 线 |
| 12 V 来源 | 独立 USB-C PD 电源 + 12 V 诱骗模块 + 转接板辅助 12 V/GND 输入 |
| 3.3 V 来源 | 雷电/USB4 M.2 盒，经 M.2 插槽和转接板送入主板 |
| JTAG | Xilinx Platform Cable USB（型号 `DLC9LP`）及转接排线 |
| 散热 | 主板上的铝制散热器和风扇 |

本仓库 XDC 和 MIG pin map 对应本次实测主板。

扩展 IO 板不属于 XDMA 数据通路，也不是运行本项目的必要部件。

## 我用的启动顺序

这次实测使用 Windows 完成 Vivado/JTAG，再重启到 Persistent Live Ubuntu。
如果开发机本身就是 AMD 支持的 x86-64 Linux，可以在同一系统安装 Vivado，
完成 JTAG 配置后继续枚举、驱动和 DMA，不需要换系统。

本次跑通时的顺序如下：

1. 断电完成 M.2↔PCIe、辅助 12 V、JTAG 和散热连接；原存储子板不连接，
   J1–J4 无外部驱动，W26 保持高阻。
2. 接通 M.2 外接盒和独立 PD 12 V 路径，启动 Windows。
3. 用 Vivado Hardware Manager 或 `fpga/program_sram.tcl` 写入 FPGA 易失 SRAM。
4. 保持两路供电，重启主机并选择 Ubuntu。
5. 运行 `linux/01_probe.sh`；看到唯一 `10ee:7024` 后继续构建、加载和 DMA。
6. 测试结束后运行 `linux/99_cleanup.sh`，再正常关闭 Ubuntu 和两路供电。

## 板上实测电平和相关引脚

- 本次主板 FPGA IO 高电平实测为 1.8 V，标为 2V5 的网络实测为 2.5 V。
- J1–J4 上重复出现的电阻识别脚用于区分存储子板型号；主板默认下拉，不应在
  未知状态下作为普通推挽输出。
- 如果未来拆除识别电阻并把相应脚改成普通 IO，需要重新维护原理图、XDC、
  电气规则和软件定义。
- W26 的主板功能仍未最终确认。本仓库不把它用于 XDMA，也不把它做成顶层
  端口；配置后使用 `Pullnone`，外部保持高阻观察。
- 12 V 经转接板辅助输入进入主板；M.2 路径承担 PCIe 信号和 3.3 V。
- 板上高速 Bank 的电压由 PCIe 输入侧决定；辅助 12 V 不是高速 Bank 电压的
  设定来源。
