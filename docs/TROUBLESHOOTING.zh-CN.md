# 这次踩过的坑与排查

我把实机调试中遇到的问题按“现象 → 原因 → 处理”整理在这里。遇到故障时，
先确认 PCIe 枚举，再看驱动绑定和设备节点，最后才进入 DMA 与 DDR 数据排查。

## 1. `lspci` 看不到 `10ee:7024`

**现象：** Ubuntu 中找不到 Xilinx endpoint，驱动也没有可绑定的设备。

**常见原因：** FPGA 没有在主机枚举前完成配置，或雷电授权、供电、线缆、
REFCLK、PERST#、M.2 转接方向和冷启动顺序存在问题。

**处理：**

```bash
lspci -Dnn
lspci -Dtv
sudo dmesg -T | grep -Ei 'pcie|thunderbolt|usb4|aer|10ee|7024' | tail -n 300
```

先看 DONE/EOS/INIT_B，再沿着主机、雷电盒、M.2 转接板和 FPGA 逐段检查。
endpoint 尚未枚举时，安装或重载 XDMA 驱动不会改变结果。

## 2. Ubuntu 启动盘进不了系统，或持久化分区报 I/O 错误

**现象：** UEFI 启动后退回 BIOS、只进入 `grub>`，或者关机时出现
`attempt to access beyond end of device`、Buffer I/O error、JBD2 journal
abort。

**原因：** Rufus 写盘完成只代表镜像复制结束；启动链、分区尺寸和
`casper-rw` 的实际读写还没有经过验证。出现越界或 journal abort 时，
分区表、文件系统尺寸或 U 盘介质可能已经不一致。

**处理：** 重新制作启动盘后完成一次真实启动，并创建 marker、重启、再次
读取。进入测试前确认：

```bash
findmnt -T /
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,SERIAL,TRAN
sudo dmesg -T | grep -Ei 'beyond end|buffer i/o|jbd2|ext4.*error'
```

根 overlay 的 source 应为 `/cow`，`casper-rw` 应位于目标 U 盘。看到文件系统
越界或日志中止时先停止写入，检查或重建启动盘。

## 3. Vivado 工程创建或实现失败

**现象：** MIG/IP 生成失败、Windows 报路径过长、Vivado 启动时提示
`Unable to load Tcl app xilinx::xsim`，或者实现后 timing/DRC 不通过。

**原因：** MIG 和 XDMA 会生成很深的目录；损坏的用户 Tcl Store catalog
也可能让 Vivado 在仓库脚本运行前退出。另一些失败来自设计本身，例如 PCIe
100 MHz REFCLK 缺少显式时钟约束，或 MIG 的 64-bit 数据配置与 XDC 中的
byte lane 数量不一致。

**处理：** 使用短的、事先不存在的绝对构建目录，从 `fpga/build.tcl` 启动：

```powershell
vivado -mode batch -source fpga/build.tcl -tclargs C:\work\mb1 --write-bitstream
```

DDR3 x64、ECC Disabled 对应 DQ 0–63、DM 0–7、DQS_P/N 0–7；不要保留第九组
byte lane。完整保留 Vivado log、DRC、setup、hold 和 bus-skew 报告。

若 Vivado 在项目创建前就报 Tcl Store 错误，先关闭所有 Vivado 进程并保存
环境信息，再按 [`fpga/README.md`](../fpga/README.md) 的步骤检查当前版本的
用户 Tcl Store。不要把生成目录当成唯一源码副本。

## 4. Linux 7.0 上 XDMA 驱动构建失败

**现象：** 构建时找不到 `libxdma_api.h`，或者补丁提示行内容相同但行尾不同。

**原因：** 旧版 vendor Makefile 使用 `EXTRA_CFLAGS`，新 Kbuild 没有正确取得
include path；原文件使用 CRLF，且带有旧内核安装路径。

**处理：** `linux/02_build_driver.sh` 会在每个内核的临时工作副本中把 CRLF
转为 LF，再使用：

```make
ccflags-y := -I$(src)/../include
```

公开补丁同时移除了硬编码的 5.15 内核路径。原始 vendor 归档和它的 SHA-256
保持不变。构建前先确认当前内核 headers 存在：

```bash
uname -m
uname -r
test -e "/lib/modules/$(uname -r)/build/Makefile"
```

## 5. Secure Boot 拒绝 `xdma.ko`

**现象：** 模块已经签名，但 `insmod` 报 key rejection，或状态脚本认为证书
没有注册。

**原因：** 文件带有签名不代表当前内核接受该签名；证书 serial 与 Subject
Key Identifier 也不是同一个字段。实测环境中，`mokutil --test-key` 曾打印
`is already enrolled`，同时返回 RC=1。

**处理：** 按 [Secure Boot 指南](SECURE_BOOT.zh-CN.md)核对当前模块签名、
DER 证书和 MOK 状态：

```bash
./linux/03_secure_boot_status.sh /path/to/MOK.der
sudo dmesg -T | tail -n 100
```

脚本会结合完整输出判断注册状态。最终以模块实际加载、内核日志和驱动绑定为准。

## 6. `insmod` 成功，但没有 `/dev/xdma*`

**现象：** `/sys/module/xdma` 已存在，设备节点缺失或节点不属于目标 BDF。

**原因：** 模块存在和 endpoint 绑定是两件事；PCI ID、父设备或 channel 配置
不匹配都会导致节点集合不完整。

**处理：** 使用 `linux/04_load_verify.sh`。它会核对 driver symlink、唯一目标
BDF、control、H2C0/1、C2H0/1 字符设备和各节点父设备，失败时卸载本轮刚加载
的模块。不要手工创建设备节点。

## 7. 小块 DMA 通过，单次 1 GiB 请求失败

**现象：** 单次 1 GiB H2C 完成，C2H 返回 137，内核出现页面分配 warning，
并且没有 `cmp` 结果。

**原因：** 单次请求给 host buffer、页表和驱动分配带来很大压力；这个结果
不能单独证明 FPGA DDR 有错。

**处理：** 把请求拆成 64 MiB 分块：

```bash
./linux/05_dma_smoke.sh --confirm-ddr-write
./linux/06_extended_validation.sh --confirm-ddr-write chunked-1g
```

每个传输都记录 size、address、channel、H2C/C2H 返回码、hash 和 `cmp`。
本仓库脚本把单次请求限制为 64 MiB，并为每次操作设置 30 秒 timeout。

## 8. 高地址疑似回卷，或不确定 FPGA 里是哪一版映像

**现象：** 低地址读写正常，但无法判断 4 GiB 空间是否发生截断、回卷或镜像；
PCI ID 与设备节点看起来相同，也不能区分两个不同 bitstream。

**原因：** “写一个地址、立即读一个地址”的测试可能看不到后写覆盖前地址；
当前设计也没有主机可读的 build-ID 寄存器。

**处理：** `alias-4g` 会先向多个高地址写入不同哨兵，再统一回读；完整 4 GiB
实验会先写完全部 64 个 64 MiB 块，再开始读回比较。当前映像身份用 bitstream
SHA-256 与 JTAG 报告关联；后续可增加独立 BAR 中的只读 build ID。

## 9. `dmesg` 采集或错误过滤误报

**现象：** Ubuntu 24.04 的 `dmesg --time-format=raw` 直接失败，或者正常的
`timeout: h2c ... c2h ...` 参数行被当作真实超时。

**原因：** util-linux 2.39.3 不支持该时间格式；简单关键词过滤也无法区分
参数名和内核错误。

**处理：** 脚本先读取默认 `dmesg`，失败时退回当前启动的 kernel journal，
并在一轮测试中固定同一个后端。错误过滤会忽略已知参数行，但真实 timeout、
AER、页分配和存储错误仍然会失败。若日志环形缓冲区覆盖了测试前快照，缩短
测试或增大日志缓冲区后重跑。

## 10. 测速结果互相矛盾

**现象：** endpoint 显示 Gen2 ×4，某 ASMedia 上游字段显示 Gen1 ×1、内核
估算约 2.0 Gb/s，而 XDMA 工具单次 64 MiB 计时却达到约 597/563 MB/s。

**原因：** `LnkSta`、内核估算和工具内部计时观察的不是同一个范围，且这些
记录并非全部来自同一时刻。单个字段不能代表端到端吞吐。

**处理：** 保存完整拓扑，并用连续多次传输的总字节数和外部墙钟时间建立
基准：

```bash
lspci -Dtv
sudo lspci -Dvvnn
```

更换线缆、盒子、转接板或主机时每次只改一个变量，同时记录每一跳的
`LnkCap/LnkSta`、CPU 占用和数据校验结果。

## 11. 测试后无法卸载

**现象：** cleanup 返回失败，模块或 `/dev/xdma*` 节点仍然存在。

**原因：** 仍有进程打开设备节点，或者节点清理尚未完成。

**处理：** 关闭占用 `/dev/xdma*` 的本轮测试进程，再运行：

```bash
./linux/99_cleanup.sh
```

脚本只在模块和设备节点都消失后返回 `CLEANUP_RC=0`；失败时会保留 ownership
marker，便于下一次继续定位。
