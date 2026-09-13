# 踩坑记录

这些问题都在本次联调中实际出现过，或由最终证据直接暴露。

## 启动盘

- Rufus 显示“准备就绪”只证明写盘结束，不证明机器能启动，也不证明
  `casper-rw` 可重启保存。
- 一次启动中，Partition 1 直接退回 BIOS，Partition 3 只进入 `grub>`；
  主分区对 GRUB 显示 unknown filesystem。
- 另一次运行中，`sda2` 报
  `attempt to access beyond end of device`、Buffer I/O error 和 JBD2
  journal abort。出现这些错误后继续写入只会扩大不确定性。
- 最终采用重新制作、实际启动、marker 重启验证和 storage guard，才把
  Live USB 当作可用环境。

## FPGA 构建

- FPGA 构建输入必须和生成目录分开。仓库只维护 Tcl、XDC 和 MIG 配置，
  Vivado 缓存、生成 IP、DCP、网表和 bitstream 都进入独立构建目录。
- PCIe 100 MHz REFCLK 必须有显式时钟约束；只看到差分管脚约束不代表
  时序分析已经拥有正确时钟。
- Setup、hold、DRC 和 bus skew 必须各自成为硬失败门。普通 timing summary
  不会自动把所有 bus-skew 结果当成脚本退出条件。
- DDR3 x64 且 ECC Disabled 时，数据边界只能是 DQ 0–63、DM 0–7、
  DQS_P/N 0–7；任何索引 8 的第九组数据 byte lane 都必须清除。配置源和
  XDC 必须互相一致。
- Windows 路径过深会让 MIG 生成文件触发路径长度问题。使用短的真实构建
  路径，避免把唯一源码副本变成生成目录。
- 某次环境出现损坏的用户 Tcl Store catalog；最终只在 Vivado 进程的
  `auto_path` 中加入安装目录副本，没有修改 Vivado 安装文件。
- “构建出 bitstream”不等于“该 bitstream 已实机验收”。发布证据必须把
  构建文件 SHA-256 与 JTAG 实际使用文件对应起来。

## 驱动

- Xilinx XDMA 老 Makefile 的 `EXTRA_CFLAGS` 在 Linux 7.0 构建中没有
  正确传递 include path，导致找不到 `libxdma_api.h`。
- 把它改为 `ccflags-y` 并使用 `-I$(src)/../include` 后构建通过。
- Vendor Makefile 使用 CRLF；补丁前只对工作副本标准化行尾。
- 旧 Makefile 还硬编码删除某个 5.15 内核路径，公开补丁已移除。

## Secure Boot

- 模块“已经签名”不等于当前内核接受它；真正结论来自 `insmod`、内核日志
  和驱动绑定。
- 证书 serial 与 Subject Key Identifier 不是同一字段，不能互相比较。
- 当前 `mokutil --test-key` 曾明确打印 `is already enrolled`，返回码却
  是 1；脚本因此按完整结果文本判断，不单独依赖返回码。
- MOK 操作前保存 BitLocker recovery key，Secure Boot 全程保持开启。

## DMA

- 单次 1 GiB 的 H2C 成功、C2H 返回 137，且没有 compare，不能据此给 DDR
  判死刑。
- 改成 16 × 64 MiB 后，前 1 GiB 全部写入再逐块回读，逐字节一致。
- 每个测试都要记录 size、address、channel、H2C/C2H RC、hash 和
  `cmp`，否则“跑完了”无法审计。
- 高地址测试应先写不同哨兵，再全部回读；写一个读一个无法有效发现某些
  后写覆盖前地址的 alias。
- PCI ID 和设备节点不能证明当前 FPGA 映像及 DDR 地址映射。执行写测试前
  仍要确认映像来源，最好由 FPGA 内只读 build ID 提供机器可核验身份。

## PCIe

- Endpoint 显示 5 GT/s ×4 不等于主机端到端就是 Gen2 ×4。
- `lspci`/内核显示某 ASMedia 上游段为 2.5 GT/s ×1、估算约 2.0 Gb/s，
  但 XDMA 工具的 64 MiB 计时又报告约 597/563 MB/s；两组数不能同时代表
  端到端吞吐，且并非同一时刻采集。
- 枚举、驱动、DMA、吞吐和长时间稳定性是五个不同结论。

## 脚本

- `findmnt -M /cow` 是错的：`/cow` 是根 overlay 的 source，应使用
  `findmnt -T /` 查看根挂载。
- `df -P` 与 `--output` 互斥；使用 `df -B1 --output=avail`。
- 证据采集失败也必须保留原退出码并做 best-effort 收尾。
- 清理脚本不能在节点仍存在时删除 ownership marker。
