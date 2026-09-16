# Memblaze K7 XDMA Lab

我手里这块 Memblaze/PBlaze3 主板原来的存储子板已经不在了，核心是 Kintex-7
`XC7K325T`，板上还有 4 GiB DDR3。原厂资料没有公开，所以我从实物测量
入手，把 PCIe、DDR3 和 JTAG 路径重新整理出来，最后让它通过雷电 4 在
普通 x86 主机上跑通了 XDMA。

现在这套工程可以直接用 Vivado 2026.1 从源码生成 bitstream，通过 JTAG 写入
易失 SRAM，然后在 Ubuntu 下枚举为 `10ee:7024`、加载 XDMA 驱动，并对板上
DDR3 做 H2C/C2H 数据往返。我已经跑完双通道并发和完整 4 GiB 分块校验，
64/64 块全部一致。

[English](README.md) · [文档导航](docs/README.md) ·
[实测结果](docs/VALIDATED_RESULTS.zh-CN.md) ·
[硬件连接](docs/HARDWARE_SETUP.zh-CN.md) ·
[现状与后续](docs/OPEN_ITEMS.zh-CN.md)

`v0.1.0-lab` 是这次实机调试整理出的第一版。Vivado 干净构建、JTAG 配置和
Ubuntu 测试使用的是同一个 bitstream，整套流程已经在实机跑完。完整 FPGA
构建入口是 `fpga/build.tcl`。

![本次成功使用的连接拓扑](docs/images/wiring-overview.svg)

我这次用 Flow Z13、雷电/USB4 M.2 外接盒和 M.2 转 PCIe ×4 转接板搭了这条
链路。12 V 由独立 USB-C PD 电源和诱骗模块提供，3.3 V 来自 M.2 插槽；两路
供电从 Windows 下配置 FPGA 一直保持到 Ubuntu 测试结束。板上两条电源轨
完全隔离且不会回灌，高速 Bank 电压由 PCIe 输入侧决定。

## 这次用到的硬件

![本次器材断电平铺总览](docs/images/hardware-parts-overview.jpg)

![原生 Ubuntu 下进行 XDMA 调试](docs/images/xdma-debug-session.jpg)

![实机通电运行状态](docs/images/hardware-running.jpg)

具体连接方式见[硬件连接](docs/HARDWARE_SETUP.zh-CN.md)。

## 你可以直接拿到什么

我把 FPGA 工程、Linux 驱动、测试脚本和这次实机日志整理到了一起：

- 用 Vivado 2026.1 从源码生成 XDMA、MIG 和完整 bitstream；
- 在 Linux 7.0 上构建并加载 XDMA v2025.2.0 驱动；
- 检查 PCIe、BAR、Secure Boot 签名和 XDMA 设备节点；
- 运行基础 DMA、双通道并发和完整 4 GiB DDR3 分块测试；
- 保存每轮日志，并在测试结束后卸载驱动和清理设备节点；
- 查看供电、JTAG、MOK、Windows/WSL 和实际踩坑记录。

我没有把 Vivado 生成目录和 bitstream 放进 Git。clone 后直接用仓库内源码
构建即可，工程不依赖另一份 FPGA 项目、DCP 或生成检查点。构建环境需要
Vivado 2026.1 和对应的 AMD IP catalog。

## 这套数据通路怎么跑

主机通过雷电 4 和 M.2 转接链路访问 FPGA。FPGA 内部由 XDMA 把 PCIe 请求
转换到 AXI，再通过 MIG 访问板上的 4 GiB DDR3。

```text
x86-64 主机 / 原生 Ubuntu
  └─ Thunderbolt 或原生 PCIe
      └─ PCIe 转接链路
          └─ Memblaze 主板 / XC7K325T
              └─ XDMA → AXI Interconnect → 4 GiB DDR3
```

实机枚举结果为 `10ee:7024`，Subsystem 为 `10ee:0007`。测试过程中 Secure
Boot 一直开启，XDMA v2025.2.0 完成了构建、签名、加载和全部数据测试。

## 我已经跑通了什么

这次从 FPGA 干净构建一直测到完整 4 GiB DDR3 数据闭环，最终结果如下。

| 项目 | 实测结果 |
|---|---|
| 仓库 FPGA 源 | 完整构建输入位于 `fpga/`，入口为 `fpga/build.tcl` |
| 仓库映像 | Vivado 2026.1 干净构建和同一 bitstream 的实机测试均通过 |
| JTAG | XC7K325T 易失 SRAM 配置成功；没有写 configuration flash |
| PCIe | 唯一 `10ee:7024`、Subsystem `10ee:0007` 端点被枚举 |
| 驱动构建 | XDMA v2025.2.0 在 `7.0.0-31-generic` 上构建成功 |
| Secure Boot | 保持开启；MOK 注册后的本地签名模块被内核接受 |
| 驱动绑定 | control、两组 H2C 和两组 C2H 节点出现 |
| 基础 DMA | 4 KiB ch0、1 MiB ch0、1 MiB ch1 和独立 64 MiB 均逐字节一致 |
| 4 GiB 寻址 | 0、1、2、3 GiB 和 `0xFFF00000` 的五个不同哨兵均一致 |
| 前 1 GiB | 16 × 64 MiB 分块写入、回读和比较全部通过 |
| 双通道并发 | channel 0/1 各 64 MiB 同时传输并分别比较通过 |
| 完整 4 GiB | 64 × 64 MiB 分块写入、回读和比较，64/64 块一致 |
| 清理 | 模块卸载，`/dev/xdma*` 节点消失 |

我也保留了干净构建的实现结果：DRC Error 0、setup WNS `+0.038 ns`、hold WHS
`+0.014 ns`，10 条 bus-skew 约束全部通过。bitstream SHA-256 为
`287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5`；
bitstream 本体继续保留在 Git 之外，相同哈希已贯穿干净构建、JTAG 报告和实机
回归。详细记录见[脱敏构建证据](evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log)
和[实机证据](evidence/validated_repository_exact_image_physical_regression_sanitized.log)。

高地址检查用了五个独立哨兵，完整测试再用 64 个 64 MiB 请求覆盖全部 4 GiB。
单次 1 GiB 请求会给主机端分配带来压力，所以脚本统一按 64 MiB 分块。

## 怎么复现

如果你手里也有这块主板，可以按下面这条路径开始：接好 PCIe、两路供电、
JTAG 和散热，用 Vivado 构建并配置 FPGA，然后保持板卡供电重启到原生 Ubuntu，
依次完成枚举、驱动和 DMA 测试。连接方式见[硬件连接](docs/HARDWARE_SETUP.zh-CN.md)。

### 1. 构建并配置 FPGA

安装 Vivado 2026.1，并确保许可证覆盖 Kintex-7 器件和本设计使用的 IP。
AMD 官方把年度
[Vivado BASIC](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html)
列为 0 美元且覆盖全部 7 Series；
[PG195](https://docs.amd.com/r/en-US/pg195-pcie-dma/Licensing-and-Ordering)
说明 XDMA 在 Vivado EULA 下不另收费。我这次使用 60 天 Enterprise 评估许可
完成干净构建。按官方表格，免费的 BASIC 覆盖 7 Series，XDMA 本身不另收
IP 费用；BASIC 环境还没有在本机重跑。
仓库内 FPGA 构建输入为：

- `fpga/build.tcl`：创建工程、综合实现、检查报告和可选 bitstream；
- `fpga/create_project.tcl`：创建工程和源码集合；
- `fpga/bd/create_design.tcl`：XDMA 到 DDR 的 block design；
- `fpga/constraints/board.xdc`：板级与时序约束；
- `fpga/mig/memblaze_ddr3.prj`：DDR3 MIG 配置；
- `fpga/program_sram.tcl`：只写易失配置 SRAM。

具体命令见 [`fpga/README.md`](fpga/README.md)。写入前检查 DRC、setup、
hold 和 bus-skew 报告。完全断电后 SRAM 映像会消失，必须在主机 PCIe 枚举
前重新配置。

```powershell
& 'C:\AMD\Vivado\2026.1\bin\vivado.bat' -mode batch `
  -source C:/work/memblaze-k7-xdma-lab/fpga/build.tcl `
  -tclargs C:/work/memblaze-build --write-bitstream
```

`C:/work/memblaze-build` 必须是绝对路径且事先不存在。工程生成在
`p/`，报告位于 `reports/`，bitstream 为构建根目录下的
`memblaze_k7_xdma_wrapper.bit`。Windows 建议使用短路径。

### 2. 在原生 Ubuntu 下跑测试

建议使用原生 x86-64 Ubuntu，或完成重启持久化验证的 Live 系统。Ubuntu
24.04 可用下面的命令一次装齐公开脚本实际调用的依赖：

```bash
sudo apt update
sudo apt install --yes \
  bash coreutils diffutils gawk grep sed tar git build-essential patch kmod \
  pciutils mokutil openssl sudo udev util-linux psmisc \
  "linux-headers-$(uname -r)"

# 可选：只有需要用 boltctl 查看雷电授权状态时才需要。
sudo apt install --yes bolt
```

如果使用 Persistent Live，给根持久化层留出至少 2 GiB，并保证 `/dev/shm`
有 256 MiB 可用空间。

运行 DDR 写测试前，先加载由本仓库生成的 bitstream；`10ee:7024` 只说明
PCIe 端点已经出现。

```bash
git clone https://github.com/HwzLoveDz/memblaze-k7-xdma-lab.git
cd memblaze-k7-xdma-lab

# 确认 PCIe 端点
./linux/01_probe.sh

# 构建驱动
./linux/02_build_driver.sh

# 查看 Secure Boot、模块签名和 MOK 状态
./linux/03_secure_boot_status.sh /path/to/your-public-mok.der

# 加载并检查 XDMA
./linux/04_load_verify.sh

# 运行 DDR 数据测试
./linux/05_dma_smoke.sh --confirm-ddr-write
./linux/06_extended_validation.sh --confirm-ddr-write alias-4g
./linux/06_extended_validation.sh --confirm-ddr-write chunked-1g
./linux/07_release_advanced.sh --confirm-ddr-write

# 清理
./linux/99_cleanup.sh
```

如果想完整复演这次发布测试，可以直接用
[一次性精确映像回归](docs/EXACT_IMAGE_REGRESSION.zh-CN.md)。它会核对 bitstream
和 JTAG 记录，把驱动构建、DMA、内核日志和清理收进同一个 run ID。

运行时会先找到唯一目标端点，再核对 control、H2C0/H2C1 和 C2H0/C2H1
节点。日志和基础测试数据保存在 `$HOME/memblaze-xdma-results/`。

MOK 创建、注册和模块签名见
[Secure Boot 指南](docs/SECURE_BOOT.zh-CN.md)，整个流程保持 Secure Boot 开启。

## 为什么测试放在 Ubuntu

Windows 这边负责 Vivado 构建、JTAG 下载和 PCIe 枚举。数据测试放在原生
Ubuntu，是因为 XDMA Linux 驱动可以直接从仓库源码构建，也能通过 sysfs、
`dmesg` 和 `/dev/xdma*` 完整观察设备状态。普通 WSL2 不能直接接管由 Windows
管理的这个雷电 PCIe 端点，所以没有用 WSL 做 DMA。详见
[Windows 与 WSL](docs/WINDOWS_WSL.zh-CN.md)。

## 许可

除文件另有说明外，本项目原创文件使用 MIT License。随附 XDMA 快照和
BSD Kbuild 补丁保留各自许可。Vivado 和 AMD/Xilinx IP 是外部工具依赖，
不随仓库分发。详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
和 [`NOTICE.md`](NOTICE.md)。
