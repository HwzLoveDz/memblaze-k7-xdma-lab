# Memblaze K7 XDMA Lab

我手里这块 Memblaze/PBlaze3 主板的存储子板已经不在了，但板上还有一颗
Kintex-7 `XC7K325T` 和 4 GiB DDR3。我从实物测量开始重新整理硬件，做了一套
可从源码构建的 FPGA 工程，最后把它变成了一张可以通过雷电 4 使用的 XDMA 卡。

仓库里已经包含 Vivado 2026.1 的完整构建输入、固定版本的 Linux XDMA 驱动和
实机测试脚本。现在它可以从干净 clone 生成 bitstream，通过 JTAG 配置 SRAM，
在 Ubuntu 下枚举为 `10ee:7024`，并完成全部 4 GiB DDR3 的写入、回读和比较。

[English](README.md) ·
[硬件连接](docs/HARDWARE_SETUP.zh-CN.md) ·
[FPGA 构建](fpga/README.md) ·
[实测结果](docs/VALIDATED_RESULTS.zh-CN.md) ·
[完整回归](docs/EXACT_IMAGE_REGRESSION.zh-CN.md) ·
[故障排查](docs/TROUBLESHOOTING.zh-CN.md)

![本次实测连接拓扑](docs/images/wiring-overview.svg)

## 已经跑通的部分

| 阶段 | 实测结果 |
| --- | --- |
| FPGA 构建 | Vivado 2026.1 干净构建；DRC Error 0，setup WNS +0.038 ns，hold WHS +0.014 ns |
| 配置 | 通过 JTAG 写入 XC7K325T 易失 SRAM |
| PCIe | 唯一 `10ee:7024`、Subsystem `10ee:0007` 端点 |
| Linux | XDMA v2025.2.0 在 `7.0.0-31-generic` 上构建并加载，Secure Boot 保持开启 |
| DMA | 两组 H2C/C2H 引擎，基础往返和双通道并发比较通过 |
| DDR3 | 五个高地址哨兵和 64 × 64 MiB 全容量比较通过 |

干净构建和实机测试使用的 bitstream SHA-256 都是
`287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5`。
bitstream 由本地构建生成，不放进 Git。完整数字和两份精简证据见
[实测结果](docs/VALIDATED_RESULTS.zh-CN.md)。

<p align="center">
  <img src="docs/images/xdma-debug-session.jpg" width="900"
       alt="原生 Ubuntu 下进行 XDMA DDR3 校验">
</p>

## 硬件链路

这次使用 ASUS ROG Flow Z13、UGREEN 雷电/USB4 M.2 外接盒和 M.2 M-Key 转
PCIe ×4 转接板。M.2 插槽承担 PCIe 链路和 3.3 V 供电，独立 USB-C PD 电源
通过诱骗模块向转接板提供 12 V。JTAG 使用 Xilinx Platform Cable USB DLC9LP。

Windows 下用 Vivado 配置 FPGA SRAM 后，板卡保持供电，主机重启进入原生
Ubuntu，再完成 PCIe 枚举和 DMA 测试。实物照片、器材和连接细节都在
[硬件连接](docs/HARDWARE_SETUP.zh-CN.md)。

FPGA 内部由 XDMA 提供两组 H2C 和两组 C2H 通道，AXI Memory Mapped 主口经
AXI Interconnect 和 MIG 访问 4 GiB DDR3。设计参数和地址空间跟源码放在
[`fpga/README.md`](fpga/README.md)。

## 快速开始

### 1. 构建并配置 FPGA

安装带 Kintex-7 支持的 Vivado 2026.1，在一个全新的短绝对路径中构建：

```powershell
& 'C:\AMD\Vivado\2026.1\bin\vivado.bat' -mode batch `
  -source C:/work/memblaze-k7-xdma-lab/fpga/build.tcl `
  -tclargs C:/work/memblaze-build --write-bitstream
```

检查生成的 DRC 和时序报告，再按
[`fpga/README.md`](fpga/README.md) 将 bitstream 写入易失 SRAM，并生成
对应的 JTAG 记录。

### 2. 进入原生 Ubuntu 运行 XDMA

Ubuntu 24.04 可以先装齐构建和检查工具：

```bash
sudo apt update
sudo apt install --yes \
  bash coreutils diffutils gawk grep sed tar git build-essential patch kmod \
  pciutils mokutil openssl sudo udev util-linux psmisc \
  "linux-headers-$(uname -r)"
```

第一次调试建议逐级运行，在哪一级失败就停在哪一级排查：

```bash
./linux/01_probe.sh
./linux/02_build_driver.sh
./linux/03_secure_boot_status.sh /path/to/enrolled-MOK.der
./linux/04_load_verify.sh
./linux/05_dma_smoke.sh --confirm-ddr-write
./linux/06_extended_validation.sh --confirm-ddr-write alias-4g
./linux/06_extended_validation.sh --confirm-ddr-write chunked-1g
./linux/07_release_advanced.sh --confirm-ddr-write
./linux/99_cleanup.sh
```

[精确映像一次性回归](docs/EXACT_IMAGE_REGRESSION.zh-CN.md)提供完整发布测试命令，
把 bitstream 哈希、JTAG 记录、驱动构建、4 GiB 比较、内核日志和清理收进同一
份结果。MOK 创建、注册和模块签名见
[Secure Boot 指南](docs/SECURE_BOOT.zh-CN.md)。

## 仓库内容

| 路径 | 内容 |
| --- | --- |
| `fpga/` | Vivado 工程生成、Block Design、XDC、MIG 配置和 SRAM 下载脚本 |
| `linux/` | 枚举、驱动构建、签名检查、DMA、完整回归和清理脚本 |
| `vendor/` | 固定版本的上游 XDMA 源码归档和文件清单 |
| `docs/HARDWARE_SETUP.zh-CN.md` | 本次实测连接和供电 |
| `docs/VALIDATED_RESULTS.zh-CN.md` | 构建与实机结果 |
| `docs/TROUBLESHOOTING.zh-CN.md` | 调试中遇到的问题和解决方法 |
| `docs/NEXT_EXPERIMENTS.zh-CN.md` | 接下来值得继续做的实验 |
| `evidence/` | 脱敏后的干净构建和精确映像实机回归摘要 |

## 为什么 DMA 放在 Ubuntu

Windows 负责 Vivado 构建、JTAG 下载和 PCIe 枚举。这里的数据测试放在原生
x86-64 Linux，是因为仓库内驱动可以直接绑定 PCIe 端点，并完整观察 sysfs、
`dmesg` 和 `/dev/xdma*`。普通 WSL2 不会从 Windows 手里接管这个雷电 PCIe
端点，所以不用于执行这些 DMA 测试。

## 许可

除文件另有说明外，本项目原创内容使用 MIT License。固定版本的 XDMA 源码、
Kbuild 补丁和 MIG 配置保留各自的上游条款，详见
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和 [`LICENSES/`](LICENSES/)。
