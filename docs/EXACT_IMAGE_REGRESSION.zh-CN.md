# 精确映像一次性实机回归

`linux/run_exact_image_regression.sh` 用于把 Windows 下的 JTAG SRAM 下载证据
和同一次上电周期里的 Ubuntu XDMA 实验绑定到一个 run ID。它适合已经验证过
持久化 Ubuntu Live USB、MOK 已注册，并希望一次进入 Linux 跑完发布验收的人。

它不会注册或创建 MOK，也不会修改 Secure Boot、EFI、BitLocker、主机磁盘分区、
FPGA configuration flash 或启动项。它会覆盖 FPGA 外部 DDR 的测试范围，并在
持久化 HOME 中构建驱动、写日志和生成证据包。

## Windows 阶段

1. 确认要测试的是 `RELEASE_MANIFEST.json` 中干净构建记录的确切 bitstream。
2. 按 [`fpga/README.md`](../fpga/README.md) 的命令运行
   `fpga/program_sram.tcl`，生成：

   - `jtag_program_status.txt`
   - bitstream 自身的 SHA-256 sidecar，例如
     `memblaze_k7_xdma_wrapper.bit.sha256`
   - JTAG 报告自身的 SHA-256 sidecar：`jtag_program_status.txt.sha256`

3. 核对 bitstream sidecar 中的 SHA-256 与 manifest 完全相同；报告 sidecar
   必须是 `jtag_program_status.txt` 本身的 SHA-256，不能再次填写 bitstream hash。
   Windows 生成的 CRLF 报告和 sidecar 可以直接使用：脚本先按原始字节校验报告
   hash，再只在内存中转换 LF 供字段解析，证据包仍保留原始报告。
4. 把当前仓库快照、bitstream、JTAG 报告及各自 sidecar 放到 Ubuntu 能从
   Live USB 读取的位置。
   不要以挂载 Windows 内部 NVMe 的方式给脚本提供文件。
5. 保持 FPGA 外部电源不断电，重启主机并选择 Ubuntu Live USB。SRAM 映像在
   FPGA 断电后会丢失；主机重启和 PCIe PERST# 不等于 FPGA 断电。

脚本会拒绝以下 JTAG 证据：hash 不等于 manifest、并非 XC7K325T、配置状态
不完整、出现 CRC error、DONE/EOS/INIT_B/GWE 未置位、存在 cfgmem 目标，或报告
本身包含 Error 字段。这个链条仍含一个人工事实：操作员必须确认从 JTAG 下载
到进入 Ubuntu 期间 FPGA 电源一直保持。当前设计没有能从主机读取的 build-ID
寄存器，因此 PCI ID 本身不能证明 SRAM 中的具体 bitstream。

## Ubuntu 前置检查

开始前应已经满足：

- `$HOME/XDMA_PERSISTENCE_MARKER.txt` 经重启验证仍存在；
- `findmnt -T / -n -o SOURCE` 输出 `/cow`；
- `casper-rw` 位于目标 USB，且知道该 USB 至少 16 字符的序列号前缀；
- Windows 内部 NVMe、device mapper 和 `/boot/efi` 都没有挂载，内部
  NVMe/device mapper 也没有被启用为 swap；
- Secure Boot 仍为 Enabled；
- 现有 MOK 的 DER 公钥和私钥仍在，公钥已经在 MOK Manager 注册；
- 当前内核头文件、构建依赖、`pciutils`、`mokutil`、OpenSSL 和
  `systemd-inhibit` 已安装，且 logind 可用；
- `/dev/shm` 至少空闲 384 MiB、HOME 至少空闲 2 GiB；
- FPGA 供电和散热稳定，存储子板未连接，J1–J4/W26 没有外部驱动冲突。

总控会先通过 `systemd-inhibit` 为当前进程获取 `idle` 阻止锁，避免长测期间
因桌面空闲而自动挂起。进程退出后该锁自动释放，不会修改系统电源策略；本轮
仍不要手动执行挂起、休眠或关机。

内核日志采集兼容 Ubuntu 24.04 随附的 util-linux 2.39.3：脚本使用默认
单调时间戳的 `dmesg`，读取失败时才退回当前启动的 kernel journal。选定后端
会贯穿同一组前后快照。若两个来源均不可读，脚本会在任何 FPGA DDR 写入前
停止，并把每次尝试的命令、退出码和错误输出保存下来。

驱动构建之前还会提前确认 x86-64 架构、编译工具、当前内核的 headers 和
`scripts/sign-file`；MOK 公钥须可由当前用户读取，私钥须由 root/当前用户持有
且权限为 0400/0600，并且公私钥确实匹配、DER 证书可解析、`mokutil` 明确报告
该证书已注册。随后真实执行仓库的 kernel-log 兼容性合约；这些前置条件任一
失败都会先停下来，避免先花时间编译或进入 DMA。

先用 `lsblk -o NAME,PATH,SIZE,MODEL,SERIAL,TRAN` 找到承载 `casper-rw` 的
USB 整盘序列号前缀。Ubuntu 有时会在 Windows 所见的 USB 序列号后追加字符，
所以脚本接受至少 16 字符的受信前缀。不要把内置 NVMe 的序列号填给脚本。

## 一条命令跑完整套实验

从仓库根目录运行，所有路径都替换为本机真实路径：

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

也可以额外传入：

```bash
--expected-bitstream-sha256 64位小写SHA256
```

若传入该参数，它必须与 manifest 完全相同；不传时脚本严格从 manifest 读取。

脚本依次执行：

1. 在第一次持久化写入前检查 HOME、NVMe、EFI、`/cow`、USB 身份、存储错误、
   Secure Boot、剩余内存和磁盘空间；
2. 校验 Windows JTAG 报告和 SHA-256 sidecar；
3. 运行仓库 validator；
4. 运行 `01_probe.sh`，保存唯一端点、完整 `lspci -vv`、BAR0 资源大小和链路；
5. 保留旧构建目录并从固定源码快照重新解包、打补丁和构建；
6. 用现有 MOK 私钥签名新模块，以 `03_secure_boot_status.sh` 确认公钥已注册；
7. 加载模块并确认两组 H2C/C2H 节点；
8. 跑默认基础 DMA；
9. 分别在 channel 0 和 channel 1 跑 64 MiB 往返；
10. 跑五点 `alias-4g`；
11. 跑 `16 × 64 MiB` 的 `chunked-1g`；
12. 读四个 XDMA engine ID，跑双通道并发 64 MiB，并用 64 个 64 MiB
    分块覆盖和比较完整 4 GiB DDR；可靠归属到 XDMA MSI 时还核对中断计数增长；
13. 检查完整会话的 PCIe 路径、AER、XDMA、内存和存储错误；
14. 卸载本轮 XDMA，并确认设备节点消失。

任何步骤失败都会保留已经产生的 summary、`lspci`、拓扑、`dmesg` 和子脚本
日志，并尝试运行 `99_cleanup.sh`。sudo keepalive 只在总控子进程存活期间运行；
EXIT/INT/TERM 路径都会结束并等待这个确切 PID。

## 带回 Windows 的文件

通过第一次持久化写入前的安全边界后，无论成功或失败，脚本都会打印：

```text
RUN_ROOT=...
EVIDENCE_BUNDLE=...tar.gz
EVIDENCE_BUNDLE_SHA256=...
EVIDENCE_BUNDLE_SIDECAR=...tar.gz.sha256
```

证据 tar.gz 不包含随机 DMA payload `.bin`，但包含其 SHA-256、传输返回码和
逐字节 `cmp` 结果。回到 Windows 后带回 tar.gz 和 sidecar；先核对 sidecar，
再从 `final_summary.env` 判断：

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

`IRQ_DELTA_STATUS` 和 `AER_STATUS_STABLE` 只有在内核/PCIe 路径提供可可靠归属
的计数或状态时才写 `PASS`/`yes`。若平台没有暴露这些字段，允许写
`UNAVAILABLE`，但必须同时保存对应的 `*_REASON`；不能把“不可观测”写成通过。

缺少任意一项都不能把该映像记为完整实机回归通过。保留原始证据包；公开仓库
只放去除用户名、USB 序列号、MOK 证书标识和本地绝对路径后的脱敏摘要。

## 失败恢复

- 若脚本在初始只读门禁阶段以 `STOP_BEFORE_WRITE` 停止，它尚未创建 run 目录。
  若在证据副本自校验阶段以 `STOP_BEFORE_DMA` 停止，run 目录已经创建，但驱动
  和 DMA 仍未开始。按屏幕信息核对 Live USB、挂载、bitstream 或 JTAG 证据。
- 若在驱动加载前失败，FPGA SRAM 映像仍在，只要 FPGA 不掉电即可修正后重跑。
- 若在加载后失败，脚本会调用 `99_cleanup.sh`。最终确认
  `lsmod | grep '^xdma '` 无输出，且 `ls /dev/xdma*` 找不到节点。
- 若自动清理报告节点被占用，只关闭证据里 `fuser` 列出的本轮测试进程，再运行
  `./linux/99_cleanup.sh`；不要杀死无关进程。
- 若 MOK 尚未注册，结束本次实验。MOK 注册需要独立重启，不能在这个一次性流程
  中临时绕过，也不要为此关闭 Secure Boot。
- 若端点未枚举，不要继续驱动诊断。保持 FPGA 电源，检查开机前是否已完成配置、
  雷电授权、线缆、盒子供电、REFCLK、PERST# 和 PCIe 链路。
