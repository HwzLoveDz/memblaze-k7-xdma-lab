# 分层故障排查

不要从 DMA 报错直接跳到“DDR 坏了”。按下面的门逐层判断。

## 1. 看不到 `10ee:7024`

运行：

```bash
lspci -Dnn
lspci -Dtv
sudo dmesg -T | grep -Ei 'pcie|thunderbolt|usb4|aer|10ee|7024' | tail -n 300
```

依次核对：

1. FPGA 是否在主机枚举前完成配置，DONE/EOS/INIT_B 是否正常；
2. 主板 12 V、转接方向、公共地和散热；
3. 雷电设备是否获得授权；
4. PCIe REFCLK 与 PERST#；
5. 线缆、硬盘盒、M.2 转接板和冷启动顺序。

此时不要安装或加载 XDMA 驱动。驱动不能修复一个尚未枚举的 endpoint。

## 2. FPGA 构建失败

仓库内构建从 `fpga/build.tcl` 启动。先确认使用 Vivado 2026.1、目标器件为
`xc7k325tffg900-2`，并把构建输出放在源码目录之外。完整输入为：

- `fpga/build.tcl`；
- `fpga/create_project.tcl`；
- `fpga/bd/create_design.tcl`；
- `fpga/constraints/board.xdc`；
- `fpga/mig/memblaze_ddr3.prj`。

调用形式为
`vivado -mode batch -source fpga/build.tcl -tclargs ABS_BUILD_DIR [--write-bitstream]`。
`ABS_BUILD_DIR` 必须是绝对路径且事先不存在；Windows 上优先使用短路径。

失败时保留完整 Vivado log、DRC、setup、hold 和 bus-skew 报告。不要为了
得到 bitstream 而绕过负 slack、DRC error 或 MIG 配置检查。Windows 上若
生成路径过深，改用短的真实目录重新构建。

## 3. 驱动构建失败

先确认：

```bash
uname -m
uname -r
test -e "/lib/modules/$(uname -r)/build/Makefile"
```

公开脚本只支持 x86-64，并要求当前内核对应的 headers。本次 Linux 7.0
遇到的两个具体问题已经在 `02_build_driver.sh` 中处理：

- 老 Makefile 使用 `EXTRA_CFLAGS`，新 Kbuild 没有正确获得 include path；
- vendor Makefile 是 CRLF，导致补丁认为行尾不同。

脚本只在每个内核的临时工作副本中把 CRLF 转为 LF，再把 include 选项改为
`ccflags-y := -I$(src)/../include`。原始归档及其 SHA-256 不会改变。

## 4. Secure Boot 拒绝模块

查看：

```bash
./linux/03_secure_boot_status.sh /path/to/MOK.der
sudo dmesg -T | tail -n 100
```

若内核报告 key rejection，按 [Secure Boot 指南](SECURE_BOOT.zh-CN.md)
重新核对当前 `xdma.ko` 的签名、证书和 MOK 状态。不要为了省一步直接关闭
Secure Boot。

## 5. `insmod` 成功但没有 `/dev/xdma*`

`04_load_verify.sh` 会同时检查：

- 模块是否位于 `/sys/module/xdma`；
- `10ee:7024` 的 driver symlink 是否指向 `xdma`；
- 驱动只绑定一个 PCI 设备；
- control、H2C0/1、C2H0/1 是否为字符设备；
- 每个 class device 的父设备是否是同一个 BDF。

任一条件失败都会卸载本脚本刚加载的模块。不要手工创建设备节点来掩盖
绑定问题。

## 6. 小块通过，大请求失败

本次单请求 1 GiB 的 C2H 最终返回 137，没有 compare 结果。这个现象本身
不能定位 DDR、驱动、内存分配还是超时。先执行：

```bash
./linux/05_dma_smoke.sh --confirm-ddr-write
./linux/06_extended_validation.sh --confirm-ddr-write chunked-1g
```

公开脚本把单请求限制在 64 MiB，并给每次操作加 30 秒 timeout。只有实际
回读和 `cmp` 成功，才算 DMA 数据通过。

加载和 DMA 脚本先读取无附加参数的 `dmesg`；util-linux 默认输出单调时间戳。
若 `dmesg` 本身不可读，脚本改用当前启动的 kernel journal，并在整轮测试中
固定同一个后端。两种方式都失败时会停止并保留各自的返回码和完整错误输出。
脚本再逐字节核对“测试前快照”仍是“测试后快照”的完整前缀。若环形缓冲区
或 journal 在测试期间覆盖了旧行，脚本会停止并拒绝给出无法可靠隔离新错误的
PASS；缩短测试或增大内核日志缓冲区后重新执行。

## 7. 速度明显低于预期

不要只看 endpoint 的 `LnkSta`。检查从 root port 到 endpoint 的每一跳：

```bash
lspci -Dtv
sudo lspci -Dvvnn
```

本次 endpoint 显示 Gen2 ×4，某 ASMedia 上游字段显示 Gen1 ×1，内核估算
约 2.0 Gb/s；但 XDMA 工具的 64 MiB 计时报告约 597/563 MB/s。后者超过
Gen1 ×1 理论能力，所以至少有一组数不代表真实端到端吞吐。更换线缆、盒子、
转接板或原生 PCIe 主机时，每次只改一个主要变量，同时保存拓扑、总字节数、
墙钟时间和重复测量，不要只凭 `LnkSta` 或工具单次 `BW` 字段下结论。

## 8. Persistent Live USB 不稳定

“能进桌面”不等于持久化可靠。至少验证：

- `findmnt -T /` 显示根 overlay 的 source 为 `/cow`；
- `casper-rw` 位于预期 U 盘，而不是内置盘；
- 创建 marker、重启、再次读取；
- `dmesg` 没有 beyond end of device、Buffer I/O、JBD2 abort；
- 内置 Windows/EFI/Recovery 分区没有挂载。

若看到文件系统越界或 journal abort，先停止写入并重建/检查启动盘，不要
继续编译驱动。

## 9. 测试后无法卸载

关闭所有占用 `/dev/xdma*` 的进程，再运行：

```bash
./linux/99_cleanup.sh
```

清理只有在模块消失且设备节点消失后才返回 `CLEANUP_RC=0`。如果失败，
保留 ownership marker 供下一次诊断，不会假装清理成功。
