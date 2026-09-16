# Windows 与 WSL：能做什么，为什么数据面用 Ubuntu

## Windows

Windows 可以完成以下工作：

- 使用仓库内 Tcl/XDC/MIG 源创建 Vivado 工程、综合、实现和生成 bitstream；
- Hardware Manager 通过 JTAG 写 FPGA 易失配置 SRAM；
- 设备管理器或 PCI 工具确认 FPGA endpoint 是否被枚举。

Windows 已经完成 JTAG SRAM 下载和 endpoint 枚举；同一个仓库 bitstream
随后在原生 Ubuntu 完成了 XDMA H2C/C2H 和完整 4 GiB DDR3 数据闭环。
Windows XDMA 数据面还没有测试。

AMD 的 Answer Record 指向两套不同资源：

- Linux 驱动公开在
  [Xilinx/dma_ip_drivers](https://github.com/Xilinx/dma_ip_drivers)；
- Windows 驱动二进制与源代码访问使用 AMD 的专门发布/申请流程，且说明
  只支持 x86 平台。

Windows 侧若没有与硬件 ID、系统版本、签名策略匹配的驱动，endpoint 即使
出现在设备管理器中，也不会自动产生可用 DMA 通道。这次公开数据测试使用
仓库中可直接构建的 Linux 驱动。

## 普通 WSL2

WSL2 运行在轻量虚拟机中。雷电盒中的 PCIe endpoint 由 Windows PCI/PnP
栈管理，普通 WSL2 不能像原生 Linux 那样直接对它执行：

- 绑定 `xdma.ko`；
- 读取对应完整 sysfs PCI 状态；
- 创建设备节点 `/dev/xdma*`；
- 通过 Linux XDMA 工具完成真实 H2C/C2H。

在 WSL 中调用 Windows 程序仍然走 Windows 驱动栈，并不会绕过 Windows
驱动需求。`usbipd` 适用于 USB 设备转发，也不会把雷电隧道里的 PCIe
endpoint 变成 WSL 可绑定设备。

## 为什么本项目使用原生 Ubuntu

在原生 Ubuntu 里，我按下面的顺序把整条数据路径跑了一遍：

1. `lspci` 证明 endpoint 枚举；
2. 固定 commit 的公开源码现场构建；
3. MOK 签名后由当前 Secure Boot 内核实际接受；
4. sysfs 证明驱动和设备节点属于目标 BDF；
5. H2C 写入、C2H 回读、SHA-256 与 `cmp` 证明数据一致；
6. `dmesg` 前后比较和独立卸载完成收尾。

如果后续拿到匹配且已签名的 Windows 驱动，可以再单独补 Windows DMA。
目前这套公开流程使用原生 Ubuntu。
