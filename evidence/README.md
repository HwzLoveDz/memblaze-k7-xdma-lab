# 实测证据

这里保留两份与当前仓库直接对应的脱敏摘要、一份原生 PCIe 复测的终端结果摘录，
以及一份解释 64 MiB 分块选择的历史负例。个人路径、邮箱、USB/JTAG 序列号、
MOK 标识和私钥信息均未进入仓库。

| 文件 | 内容 |
| --- | --- |
| `validated_repository_clean_build_vivado_2026_1_sanitized.log` | 当前 FPGA 源码在 Vivado 2026.1 下的干净构建、实现检查、source-set hash 和 bitstream hash |
| `validated_repository_exact_image_physical_regression_sanitized.log` | 同一 bitstream 的 JTAG、PCIe、Secure Boot、XDMA、双通道、完整 4 GiB 数据比较和清理 |
| `native_pcie_msa2_console_summary_sanitized.log` | MS-A2 原生 PCIe Gen2 ×8 上同一 DMA 脚本的终端结果摘录；阶段日志仍在实验 U 盘 |
| `historical_single_request_1g_failure_sanitized.log` | 单次 1 GiB 请求未完成数据比较的边界记录；后续正式流程改用 64 MiB 分块 |

前两份 `validated_repository_*` 记录使用相同的 bitstream SHA-256：

```text
287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5
```

第一份回答“当前源码能否得到这张映像”，第二份回答“这张映像是否在实机完成
数据闭环”。枚举、驱动绑定和 DMA 数据一致性在第二份记录中分别列出。

本次实机回归使用 64 MiB 请求完成：

- channel 0/1 基础和并发 H2C/C2H 比较；
- 五个 4 GiB 高地址窗口哨兵；
- 前 1 GiB 的 16 块连续比较；
- 完整 4 GiB 的 64 块写入、回读和逐块比较；
- 测试后的内核错误扫描和 XDMA 清理。

完整测试说明见
[`docs/VALIDATED_RESULTS.zh-CN.md`](../docs/VALIDATED_RESULTS.zh-CN.md)，复演命令见
[`docs/EXACT_IMAGE_REGRESSION.zh-CN.md`](../docs/EXACT_IMAGE_REGRESSION.zh-CN.md)。
`RELEASE_MANIFEST.json` 记录这两份文件的 SHA-256，
`python tools/validate_repo.py --release` 会同时核对内容和哈希。
