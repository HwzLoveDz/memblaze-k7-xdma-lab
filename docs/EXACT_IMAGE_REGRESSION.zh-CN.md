# 精确映像一次性实机回归

`linux/run_exact_image_regression.sh` 把 Windows 下的 JTAG SRAM 下载证据和
同一次上电周期里的 Ubuntu XDMA 实验绑定到一个 run ID。持久化 Ubuntu、MOK
和依赖准备好以后，从仓库根目录运行这一条命令：

```bash
./linux/run_exact_image_regression.sh \
  --confirm-exact-image-and-ddr-write \
  --bitstream /path/to/memblaze_k7_xdma_wrapper.bit \
  --bitstream-sha256 /path/to/memblaze_k7_xdma_wrapper.bit.sha256 \
  --jtag-report /path/to/jtag_program_status.txt \
  --jtag-report-sha256 /path/to/jtag_program_status.txt.sha256 \
  --mok-certificate /path/to/enrolled-MOK.der \
  --mok-private /path/to/enrolled-MOK.priv \
  --expected-live-disk-serial-prefix YOUR_LIVE_USB_SERIAL_PREFIX
```

所有路径都替换为本机真实路径。USB 序列号前缀从
`lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN` 读取，至少填写 16 个字符。
可选参数 `--expected-bitstream-sha256` 接受 64 位小写 SHA-256；不传时脚本
直接使用 `RELEASE_MANIFEST.json` 中的值。

## Windows 交接到 Ubuntu

先按 [`fpga/README.md`](../fpga/README.md) 的 JTAG 命令生成四个文件：

- `memblaze_k7_xdma_wrapper.bit`；
- `memblaze_k7_xdma_wrapper.bit.sha256`；
- `jtag_program_status.txt`；
- `jtag_program_status.txt.sha256`。

bitstream sidecar 必须等于 manifest 记录的 bitstream SHA-256；报告 sidecar
是 JTAG 报告自身的 SHA-256。Windows 生成的 CRLF 报告可以直接交给脚本，
它按原始字节校验 hash，再在内存中解析文本。

把仓库快照和这四个文件放在 Live USB 可读取的位置。JTAG 下载后保持 FPGA
两路供电连续，重启主机并选择 Ubuntu；SRAM 映像在 FPGA 断电后会丢失。

## Ubuntu 前提

- `$HOME/XDMA_PERSISTENCE_MARKER.txt` 已经过重启验证，根 overlay source
  为 `/cow`，`casper-rw` 位于目标 USB；
- 内部 NVMe、device mapper 和 `/boot/efi` 没有挂载，也没有被启用为 swap；
- Secure Boot 保持 Enabled，现有 MOK 公钥已注册，公私钥仍然匹配；
- 当前内核 headers、编译工具、`pciutils`、`mokutil`、OpenSSL 和
  `systemd-inhibit` 已安装；
- `/dev/shm` 至少空闲 384 MiB，HOME 至少空闲 2 GiB；
- FPGA 12 V、3.3 V 和散热稳定。

脚本会在第一次持久化写入前重复检查这些条件。MOK 注册需要单独重启完成，
不会在这轮实验中创建新 MOK。测试会覆盖 FPGA 外部 DDR，不会写 FPGA
configuration flash。

## 脚本会做什么

1. 检查 Live USB、HOME、内置盘挂载、Secure Boot、空间和内核日志；
2. 校验 bitstream、JTAG 报告和两个 sidecar；
3. 运行仓库 validator，探测唯一 `10ee:7024` endpoint 并保存完整
   `lspci -vv`；
4. 从固定 vendor 源码重新构建 XDMA，用现有 MOK 签名并加载；
5. 核对驱动绑定、两组 H2C/C2H 节点和四个 XDMA engine ID；
6. 执行基础 DMA、双通道 64 MiB、`alias-4g`、`chunked-1g`、双通道并发和
   完整 4 GiB 分块比较；
7. 比较测试前后的 PCIe、AER、XDMA、内存和存储日志；
8. 卸载本轮 XDMA，确认设备节点消失并生成证据包。

总控使用 `systemd-inhibit` 在进程存活期间持有 idle 阻止锁，退出后自动释放。
内核日志优先读取默认 `dmesg`，失败时退回当前启动的 kernel journal，并在
整轮测试中固定同一个后端。

## 带回 Windows 的文件

成功通过存储边界后，脚本会打印：

```text
RUN_ROOT=...
EVIDENCE_BUNDLE=...tar.gz
EVIDENCE_BUNDLE_SHA256=...
EVIDENCE_BUNDLE_SIDECAR=...tar.gz.sha256
```

带回 tar.gz 和 sidecar，先核对 sidecar，再看包内的 `final_summary.env`。
证据包不包含随机 DMA payload，但保留每次传输的 SHA-256、返回码和 `cmp`
结果。

<details>
<summary>完整通过时应看到的字段</summary>

```text
WINDOWS_JTAG_EVIDENCE=PASS
IDLE_INHIBITOR=active
PCI_ENUMERATION=PASS
XDMA_DRIVER=PASS
DMA_DATA_COMPARE=PASS
DMA_64M_BOTH_CHANNELS=PASS
EVIDENCE_alias_4g=PASS
EVIDENCE_chunked_1g=PASS
CONTROL_ENGINE_IDENTIFIERS=PASS
CONCURRENT_DMA=PASS
FULL_4G_DATA_COMPARE=PASS
ADVANCED_RELEASE_VALIDATION=PASS
PCIE_PATH_STATUS_STABLE=yes
NEW_SEVERE_KERNEL_MESSAGES=none
CLEANUP_STATUS=PASS
EXACT_IMAGE_PHYSICAL_REGRESSION=PASS
SESSION_LOG_TEE_RC=0
FINAL_EXPERIMENT_RC=0
```

`IRQ_DELTA_STATUS` 和 `AER_STATUS_STABLE` 只有在平台提供可归属的计数或状态时
才会写 `PASS`/`yes`。平台没有暴露字段时会写 `UNAVAILABLE` 和对应原因。

</details>

<details>
<summary>失败后怎么恢复</summary>

- `STOP_BEFORE_WRITE`：尚未创建 run 目录；按屏幕输出核对 Live USB、挂载和
  空间。
- `STOP_BEFORE_DMA`：run 目录已创建，但驱动和 DMA 尚未开始；检查 bitstream、
  JTAG 报告、MOK 和 endpoint。
- 驱动加载前失败：FPGA 未掉电时可以修正条件后重新运行。
- 驱动加载后失败：脚本会调用 `linux/99_cleanup.sh`。确认
  `lsmod | grep '^xdma '` 无输出，且 `ls /dev/xdma*` 找不到节点。
- 自动清理报告节点被占用：只关闭证据中 `fuser` 列出的本轮测试进程，再运行
  `./linux/99_cleanup.sh`。
- endpoint 未枚举：回到 FPGA 配置完成时机、雷电授权、供电、线缆、REFCLK、
  PERST# 和 PCIe 链路排查。

任何失败都会保留已经产生的 summary、`lspci`、拓扑、内核日志和子脚本日志。

</details>
