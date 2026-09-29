# Memblaze K7 XDMA Lab

I had a Memblaze/PBlaze3 controller board whose storage daughterboard was
missing. The board still had a Kintex-7 `XC7K325T` and 4 GiB of DDR3, so I
traced the useful hardware, rebuilt the FPGA design, and ran XDMA through both
a Thunderbolt 4 adapter and a native PCIe slot.

The repository now contains the complete Vivado 2026.1 source flow, the pinned
Linux XDMA driver, and the scripts used for the physical test. The board builds
from a clean clone, programs over JTAG, enumerates as `10ee:7024`, and passes a
full 4 GiB DDR3 write/read comparison.

[简体中文](README.zh-CN.md) ·
[Hardware](docs/HARDWARE_SETUP.zh-CN.md) ·
[FPGA build](fpga/README.md) ·
[Results](docs/VALIDATED_RESULTS.zh-CN.md) ·
[Full regression](docs/EXACT_IMAGE_REGRESSION.zh-CN.md) ·
[Troubleshooting](docs/TROUBLESHOOTING.zh-CN.md)

![Measured Thunderbolt connection topology](docs/images/wiring-overview.svg)

## Why the DMA side uses native Linux

I started with a Windows laptop, where Vivado builds, JTAG programming, and
PCIe enumeration all worked. AMD provides a Windows XDMA driver, but source
access uses a separate
[request](https://account.amd.com/en/forms/registration/xdma_windows_driver.html),
and a locally built driver must still satisfy Windows kernel-signing policy.
This repository does not include a redistributable, signed package that both
matches this card and installs under ordinary Windows policy, so the DMA tests
run on native Linux.

The Linux driver and tools are public in
[`dma_ip_drivers`](https://github.com/Xilinx/dma_ip_drivers), making it
possible to pin the source, build for the running kernel, and inspect sysfs,
`dmesg`, and `/dev/xdma*`. Ordinary WSL2 cannot take ownership of the
Thunderbolt PCIe endpoint from Windows. If the development machine already
runs a
[supported x86-64 Linux distribution](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Supported-Operating-Systems),
the Linux build of Vivado 2026.1 can keep FPGA build, JTAG, driver work, DMA,
logs, and AI-assisted debugging in one OS.

To avoid repartitioning the laptop's internal Windows/BitLocker drive, I made
an Ubuntu 24.04.5 Persistent Live USB on a 250 GB SanDisk drive, with 64 GiB
assigned to `casper-rw`. The system, driver build, MOK signing files, scripts,
and logs stay on the USB, while the internal NVMe remains unmounted during the
experiment. An existing native Linux installation makes this step unnecessary.

## What works

| Stage | Result |
| --- | --- |
| FPGA build | Clean Vivado 2026.1 build; DRC Error 0, setup WNS +0.038 ns, hold WHS +0.014 ns |
| Configuration | Volatile XC7K325T SRAM programming over JTAG |
| PCIe | One `10ee:7024`, subsystem `10ee:0007` endpoint |
| Linux | XDMA v2025.2.0 built and loaded on kernel `7.0.0-31-generic` with Secure Boot enabled |
| DMA | Two H2C and two C2H engines; basic and concurrent dual-channel comparisons passed |
| DDR3 | Five high-address sentinels and 64 × 64 MiB full-capacity comparison passed |

On an MS-A2 native PCIe slot, the link trained at Gen2 ×8. The same full-4-GiB
chunked test reached 1432 MiB/s H2C and 1108 MiB/s C2H with data comparison
and cleanup passing. See the [measured results](docs/VALIDATED_RESULTS.zh-CN.md).

The clean-build bitstream and the tested image share SHA-256
`287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5`.
The bitstream itself is generated locally and is not committed. Detailed
numbers and concise evidence records are in
[Validated results](docs/VALIDATED_RESULTS.zh-CN.md).

![XDMA DDR3 validation running in native Ubuntu](docs/images/xdma-debug-session.jpg)

## Hardware path

The original Thunderbolt setup used an ASUS ROG Flow Z13, a UGREEN
Thunderbolt/USB4 M.2 enclosure, and an M.2 M-Key to PCIe x4 adapter. The M.2
slot supplies the PCIe path and 3.3 V. A separate USB-C PD source and trigger
module supply 12 V to the adapter. JTAG is connected with a Xilinx Platform
Cable USB DLC9LP.

The board stays powered while the host reboots from Windows, where Vivado
programs FPGA SRAM, into native Ubuntu, where PCIe enumeration and DMA are
tested. Photographs, the parts list, and the exact connection are in the
[hardware guide](docs/HARDWARE_SETUP.zh-CN.md).

Inside the FPGA, XDMA exposes two H2C and two C2H channels. Its AXI memory-mapped
master reaches the 4 GiB DDR3 address space through an AXI interconnect and MIG.
The design parameters and address map are documented beside the source in
[`fpga/README.md`](fpga/README.md).

## Quick start

### 1. Build and program the FPGA

Install Vivado 2026.1 with Kintex-7 support, then build into a new short,
absolute path:

```powershell
& 'C:\AMD\Vivado\2026.1\bin\vivado.bat' -mode batch `
  -source C:/work/memblaze-k7-xdma-lab/fpga/build.tcl `
  -tclargs C:/work/memblaze-build --write-bitstream
```

This is the Windows command used for the recorded clean build. On Linux, call
`bin/vivado` from the Vivado installation and replace the repository and build
directories with absolute Linux paths. It uses the same Tcl flow, but is not
part of the current clean-build record.

Review the generated DRC and timing reports, then follow
[`fpga/README.md`](fpga/README.md) to program the resulting bitstream into
volatile SRAM and create its JTAG record.

### 2. Boot native Ubuntu and run XDMA

On Ubuntu 24.04, install the build and inspection tools:

```bash
sudo apt update
sudo apt install --yes \
  bash coreutils diffutils gawk grep sed tar git build-essential patch kmod \
  pciutils mokutil openssl sudo udev util-linux psmisc \
  "linux-headers-$(uname -r)"
```

For a first pass, run each stage separately:

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

The [exact-image runbook](docs/EXACT_IMAGE_REGRESSION.zh-CN.md) provides the
single-command release regression that binds the bitstream hash, JTAG record,
driver build, full 4 GiB comparison, kernel log, and cleanup into one result.
MOK creation and module signing are covered in the
[Secure Boot guide](docs/SECURE_BOOT.zh-CN.md).

## Repository map

| Path | Contents |
| --- | --- |
| `fpga/` | Vivado project generator, block design, XDC, MIG configuration, and SRAM programmer |
| `linux/` | Probe, driver build, signing checks, DMA tests, full regression, and cleanup |
| `vendor/` | Pinned upstream XDMA source archive and source manifest |
| `docs/HARDWARE_SETUP.zh-CN.md` | Tested hardware and power connection |
| `docs/VALIDATED_RESULTS.zh-CN.md` | Build and physical-test results |
| `docs/TROUBLESHOOTING.zh-CN.md` | Problems encountered and their fixes |
| `docs/NEXT_EXPERIMENTS.zh-CN.md` | Useful next steps for the design |
| `evidence/` | Sanitized clean-build and exact-image regression summaries |

## License

Project-authored files use the MIT License unless a file states otherwise.
The pinned XDMA source, Kbuild patch, and MIG configuration keep their
respective upstream terms; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`LICENSES/`](LICENSES/).
