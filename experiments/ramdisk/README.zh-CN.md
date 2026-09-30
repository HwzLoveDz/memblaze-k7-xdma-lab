# Memblaze FPGA RAM 盘

把板载 4 GiB DDR 挂载成 `~/FPGA_RAM`。可以往里面复制文件、打开图片或放编译临时文件；数据实际通过 XDMA 进入 FPGA DDR。掉电或重新运行启动脚本会清空内容。

本实验复用已经验证的 Gen2 ×8 XDMA/DDR 位流和 Linux 驱动，无需安装 IO 扩展板。RAM 盘的软件与位流是两个独立部分。

## 实机结果

在 MS-A2 的原生 PCIe Gen2 ×8 链路上，Ubuntu 内核 `7.0.0-31-generic` 已把 4 GiB FPGA DDR 挂载成 ext4 RAM 盘，文件管理器和普通文件命令可以直接使用。

| 测试 | 结果 |
| --- | --- |
| 64 MiB 示例文件 | 写入数据与 direct I/O 回读数据的 SHA-256 一致；写 836.15 MiB/s，读 807.99 MiB/s |
| 256 MiB 随机文件 | direct I/O 写入、读取成功；再次 direct I/O 读回的 SHA-256 与此前文件校验值一致 |
| 256 MiB 文件速度 | 写 573 MB/s，包含随机数据生成时间；direct I/O 读约 1.7 GB/s |
| 退出 | Ctrl+C 后正常卸载；NBD 断开，XDMA 驱动卸载，`RAMDISK_CLEANUP_RC=0` |

两组速度来自不同文件测试：64 MiB 示例还计算 SHA-256 并等待文件写入完成，256 MiB 的读取单独计时。原始启动与清理日志已从 U 盘取回，精简记录见[实测证据](../../evidence/ramdisk_msa2_validation.json)。

## 在现有 Ubuntu U 盘上运行

FPGA 应在主机 PCIe 枚举前完成配置。进入 Ubuntu 后先确认：

```bash
lspci -Dnn -d 10ee:7024
```

然后运行 USB 实验包：

```bash
bash /cdrom/MEMBLAZE_RAMDISK_2026-10-01/start.sh
```

脚本自动复制到持久化 HOME、安装缺少的依赖、加载已签名的 XDMA 模块、清空 FPGA DDR、连接一个空闲 NBD 设备，并在该设备上建立 ext4。唯一格式化目标是脚本自己连接的 `/dev/nbdN`；不会选择 NVMe、SATA、U 盘设备，也不调整分区或启动设置。

启动时创建并回读一个 64 MiB 文件，SHA-256 一致后显示 `RAMDISK_FILE_COMPARE=PASS`。文件测试使用 direct I/O，避免把主机缓存速度当成 FPGA 的传输速度。图形文件管理器中打开 HOME 下的 `FPGA_RAM` 即可使用。

保留启动终端，在该终端按 **Ctrl+C** 停止。脚本按顺序卸载文件系统、断开自己连接的 NBD 设备、结束自己的 nbdkit 进程，最后卸载本次加载的 XDMA。若文件仍被占用，会让你关闭文件或离开该目录，再按 Enter 重试。日志保存在 `~/memblaze-ramdisk-runs/`，退出后回传 `summary.log` 和 `file-demo.json`。

RAM 盘挂载期间不要执行其他直接写 FPGA DDR 的 DMA 测试；那些程序与文件系统共享同一片 DDR。

## 从仓库运行

先按主仓库的 Linux 步骤完成 XDMA 驱动构建和签名，再运行：

```bash
bash experiments/ramdisk/start.sh
```

依赖为 Ubuntu 的 `nbdkit`、`nbdkit-plugin-python`、`nbd-client`、Python 3 和 e2fsprogs。USB 实验包附带 Ubuntu 24.04 amd64 的离线 deb；仓库版在首次运行时通过 apt 安装。内核还需提供 `nbd` 模块；若提示缺失，可安装匹配当前内核的 `linux-modules-extra-$(uname -r)`。

## 实现与验证范围

- nbdkit Python API v2 把 512 字节扇区请求转发到 `/dev/xdma0_h2c_0` 和 `/dev/xdma0_c2h_0`。
- mmap 提供页对齐的 DMA 缓冲区，每次请求拆成至多 1 MiB；通过只读 ioctl 检查 AXI-MM incremental 模式和地址对齐。
- 读写有完整长度检查，短传输继续推进缓冲区与 FPGA 地址，零进度返回错误。
- 请求串行处理，flush 等待同步 DMA 写完成；这不提供掉电持久化。zero 会真的写入零数据，trim 不启用。
- 生产插件只接受 XDMA 索引，核对设备类型、PCIe ID `10ee:7024`、子系统 `10ee:0007` 和已绑定的 `xdma` 驱动。
- `tests/` 的普通文件后端只用于开发环境中的边界和 NBD 协议测试，生产启动脚本不使用它。

协议和接口依据：[nbdkit Python API](https://libguestfs.org/nbdkit-python-plugin.3.html)、[NBD 客户端](https://libguestfs.org/nbdkit-client.1.html)和本仓库锁定版本的 AMD XDMA 驱动。

本机 12 项测试覆盖对齐、短传输、2 GiB／4 GiB 地址边界及实际 NBD 协议；上面的实机结果覆盖挂载、文件校验和退出清理。
