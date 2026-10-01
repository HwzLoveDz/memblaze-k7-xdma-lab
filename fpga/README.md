# FPGA build

Everything needed to recreate the Vivado project is stored in this `fpga/`
directory. The repository intentionally contains source configuration rather
than generated AMD IP output, a generated HDL wrapper, or a bitstream. Vivado
regenerates those files in a separate build directory.
No other FPGA project, external Git commit, DCP, or generated checkpoint is an
input to this flow.

## Runtime data path

```text
Linux userspace
  ↕  /dev/xdma0_h2c_* and /dev/xdma0_c2h_*
xdma.ko
  ↕  PCIe / Thunderbolt bridge path
XDMA endpoint
  ↕  128-bit AXI memory-mapped master at 250 MHz
AXI interconnect and generated clock converter
  ↕  MIG user clock domain
MIG 7 Series
  ↕
4 GiB DDR3
```

H2C writes travel from host memory through XDMA into the MIG address space;
C2H reads return along the same path. The FPGA side uses a 64-bit AXI address
and maps DDR from `0x00000000` through `0xffffffff`.

The generic PF0 BAR0 setting is 128 KiB, non-prefetchable and 32-bit. XDMA's
configuration aperture inside the core is 64 KiB; these are different values.
The active BAR resources and negotiated link width/speed come from the host and
should be read from `lspci -vv` on the machine under test.

## Requirements

- An AMD-supported x86-64 Windows or Linux system with Vivado 2026.1
- A valid Vivado license for implementation and bitstream generation for
  `xc7k325tffg900-2` and the configured AMD IP
- A short absolute build path that does not already exist, for example
  `C:\work\mb1`

MIG and XDMA generate deep directory trees. A short build path is especially
useful on Windows, where long generated paths can fail during IP generation.

AMD lists the annual
[Vivado BASIC tier](https://www.amd.com/en/products/software/adaptive-socs-and-fpgas/vivado/vivado-licensing-options.html)
at $0 with all 7 Series devices.
[PG195](https://docs.amd.com/r/en-US/pg195-pcie-dma/Licensing-and-Ordering)
states that XDMA is provided at no additional cost under the Vivado EULA. The
exact clean build recorded for this repository used a 60-day Enterprise
evaluation license. BASIC has not been locally rerun, so treat it as officially
documented compatibility rather than local execution evidence; that additional
license-tier check is not a release blocker.

## Create or build from source

On Windows, set the repository and build paths from PowerShell, then run
Vivado:

```powershell
$LAB_REPO = (Resolve-Path 'C:\work\memblaze-kintex7-lab').Path
$BUILD_DIR = 'C:\work\mb1' # must not already exist
$VIVADO = "$env:XILINX_VIVADO\bin\vivado.bat"

# Create the project, regenerate IP, validate the block design, and stop.
& $VIVADO -mode batch -source "$LAB_REPO\fpga\build.tcl" `
  -tclargs $BUILD_DIR

# For a routed design and bitstream, use a new empty path and add this option:
& $VIVADO -mode batch -source "$LAB_REPO\fpga\build.tcl" `
  -tclargs C:\work\mb2 --write-bitstream
```

Adjust `$LAB_REPO` to the clone location. `XILINX_VIVADO` is normally set by
the Vivado command prompt; otherwise set `$VIVADO` to the installed
`vivado.bat` directly.

On Linux, run the same Tcl entry point with Linux paths:

```bash
VIVADO_ROOT="/tools/AMD/Vivado/2026.1"
source "$VIVADO_ROOT/settings64.sh"

LAB_REPO="$HOME/src/memblaze-kintex7-lab"
BUILD_DIR="$HOME/build/memblaze-k7-xdma"

vivado -mode batch -source "$LAB_REPO/fpga/build.tcl" \
  -tclargs "$BUILD_DIR" --write-bitstream
```

Adjust `VIVADO_ROOT` to the installation path and choose an absolute
`BUILD_DIR` that does not already exist. The recorded clean build used Windows;
this Linux command uses the same Tcl flow but is not part of that record.

The script refuses a relative or existing build directory, a Vivado release
other than 2026.1, a locked or upgradeable IP, DRC errors, negative setup or
hold slack, missing or ambiguous clocks, unexpected `check_timing` results, and
missing or violated bus-skew checks. The expected no-input/no-output-delay
entries are restricted to the MIG source-synchronous DDR interface and the
asynchronous PCIe reset. It never opens Hardware Manager and never programs
FPGA SRAM or configuration memory.

Generated files are written only below `$BUILD_DIR`:

| Result | Path |
| --- | --- |
| Vivado project | `<BUILD_DIR>/p/memblaze_k7_xdma.xpr` |
| Build reports | `<BUILD_DIR>/reports/` |
| Routed bitstream | `<BUILD_DIR>/memblaze_k7_xdma_wrapper.bit` |

The generated top-level module is `memblaze_k7_xdma_wrapper`.

The frozen 2026-09-14 clean build completed in Vivado 2026.1 with DRC Error 0,
setup WNS `+0.038 ns`, hold WHS `+0.014 ns`, and all 10 bus-skew constraints
passing. The source-set SHA-256 is
`21ced21f69c2f8265b6e61a31f1cd207b2e67c24a885ba5ff3cbddeae63812c0`;
the generated bitstream SHA-256 is
`287f0ff1e9a0bef58842d1769e782fe06ed16cf3019d8e65477ca7a688f5b1c5`.
See the [sanitized clean-build evidence](../evidence/validated_repository_clean_build_vivado_2026_1_sanitized.log).
The matching physical regression remains a separate gate.

### Tcl Store startup diagnosis

Most installations need no extra setup. If Vivado exits before project
creation with `Unable to load Tcl app xilinx::xsim`, the failure occurs before
this repository's Tcl entry point can repair anything. Do not set
`XILINX_TCLAPP_REPO` to a guessed path: an apparently plausible value can still
select an incomplete per-user catalog.

Close every Vivado process, preserve the failing `vivado.log`, and record
`XILINX_VIVADO`, `XILINX_TCLAPP_REPO`, and the contents of the versioned
per-user directory below before changing it:

```powershell
Get-ChildItem Env:XILINX* | Sort-Object Name
$UserStore = Join-Path $env:APPDATA 'Xilinx\Vivado\2026.1\XilinxTclStore'
Get-ChildItem -Force -LiteralPath $UserStore -ErrorAction SilentlyContinue
```

A reversible diagnostic is to rename that exact versioned directory while all
Vivado processes are closed, start a fresh Vivado process, and retry once. Keep
the renamed directory as the rollback copy. If the same startup failure
remains, restore the copy and repair the Vivado installation or use AMD support;
do not publish an environment-variable workaround that has not been verified
on the affected installation. The build script loads the installed `appinit`
package after startup, but it cannot replace a broken package already selected
by the launcher.

## Committed FPGA inputs

- `build.tcl` is the stable command-line entry point.
- `create_project.tcl` creates the project, regenerates IP, runs the build, and
  checks reports.
- `bd/create_design.tcl` creates and connects the block design.
- `mig/memblaze_ddr3.prj` defines the 64-bit DDR3 interface and pinout.
- `constraints/board.xdc` defines board-level PCIe, clock, reset, and
  configuration constraints.
- `program_sram.tcl` programs one reviewed bitstream into volatile FPGA SRAM.

No pre-generated `.xci`, block-design file, IP RTL, HDL wrapper, checkpoint, or
bitstream is required as an input.

The MIG `.prj` is a Vivado/MIG configuration input retained for IP revision
control as described by AMD's
[Vivado Design Methodology](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/IP-Versions-and-Revision-Control).
It and the IP products Vivado generates from it remain subject to the
applicable AMD tool and IP terms; the repository's MIT license does not replace
those terms.

## Design configuration

The design uses a 100 MHz differential PCIe reference clock and a Gen2 x8 XDMA
endpoint. XDMA exposes a 64-bit-address, 128-bit-data AXI memory-mapped master
clocked at 250 MHz. An AXI interconnect and its generated clock converter bridge
that master to the MIG user clock domain. The board's 50 MHz clock is converted
to the 200 MHz MIG reference clock.

The host-visible endpoint settings are explicit in the block-design Tcl:

- vendor/device ID `10ee:7024`
- subsystem vendor/device ID `10ee:0007`
- class code `058000`, revision `00`
- generic PF0 BAR0 setting of 128 KiB, non-prefetchable and 32-bit; BAR1 through
  BAR5 disabled
- XDMA configuration aperture setting of 64 KiB inside the core; capture the
  active host resource layout with `lspci -vv` for every exact-image regression
- two H2C and two C2H channels
- MSI enabled with one vector; MSI-X disabled
- AXI-Lite master, AXI-Lite slave, and AXI bypass disabled
- PCIe capability Gen2 x8; the negotiated link may be narrower or slower on a
  particular host or enclosure

MIG is configured for 4 GiB of DDR3 at address `0x00000000` through
`0xffffffff`, using a 64-bit data bus, eight data-mask signals, and eight
differential DQS lanes. The active MIG source contains no ninth byte lane.

The optional link-up and MIG-calibration status signals are kept internal. R24
and T20 are not top-level outputs and are not driven by this design because
their board-level loads and directions have not been independently confirmed.

There is no AXI build-ID register in this revision. DDR occupies the entire
32-bit MIG address range, so inserting a register without changing the memory
map would overlap DDR. A future build-ID should use a separately designed PCIe
BAR. Until then, record and compare the SHA-256 of the exact bitstream used for
each hardware test.

## Unused pins and W26

W26 is not a top-level port and is not driven by this design. The bitstream sets
`BITSTREAM.CONFIG.UNUSEDPIN` to the Vivado 7-series value `Pullnone`, leaving
unused user I/O without an internal pull after configuration. This also covers
unused J1-J4 user signals that are not present as top-level ports.

This setting does not remove an external resistor on the board and does not
define pin behavior during FPGA configuration. Keep W26 as an observation-only
signal until its board-level function is established.

## SRAM-only JTAG programming

After reviewing the reports and identifying the bitstream by SHA-256, program
volatile FPGA SRAM with:

```powershell
$BIT = (Resolve-Path 'C:\work\mb2\memblaze_k7_xdma_wrapper.bit').Path
$JTAG_REPORT = 'C:\work\mb2\jtag_program_status.txt' # must not exist
$BIT_SHA256_BEFORE = `
  (Get-FileHash -LiteralPath $BIT -Algorithm SHA256).Hash.ToLowerInvariant()
$MANIFEST = Get-Content -Raw -LiteralPath "$LAB_REPO\RELEASE_MANIFEST.json" |
  ConvertFrom-Json
$MANIFEST_SHA256 = `
  ([string]$MANIFEST.fpga_design.clean_build.bitstream_sha256).ToLowerInvariant()
if ($MANIFEST_SHA256 -notmatch '^[0-9a-f]{64}$') {
  throw 'Manifest clean-build bitstream SHA-256 is missing or invalid'
}
if ($BIT_SHA256_BEFORE -cne $MANIFEST_SHA256) {
  throw 'Selected bitstream does not match the repository clean-build SHA-256'
}

& $VIVADO -mode batch -source "$LAB_REPO\fpga\program_sram.tcl" `
  -tclargs $BIT $JTAG_REPORT
if ($LASTEXITCODE -ne 0) { throw "JTAG programming failed: exit $LASTEXITCODE" }

$BIT_SHA256_AFTER = `
  (Get-FileHash -LiteralPath $BIT -Algorithm SHA256).Hash.ToLowerInvariant()
if ($BIT_SHA256_AFTER -cne $BIT_SHA256_BEFORE) {
  throw 'Bitstream changed during JTAG programming'
}
$BIT_SHA256_AFTER | Set-Content -LiteralPath "${BIT}.sha256" -Encoding ascii
$JTAG_REPORT_SHA256 = `
  (Get-FileHash -LiteralPath $JTAG_REPORT -Algorithm SHA256).Hash.ToLowerInvariant()
$JTAG_REPORT_SHA256 | Set-Content -LiteralPath "${JTAG_REPORT}.sha256" -Encoding ascii
$BIT_SHA256_AFTER
$JTAG_REPORT_SHA256
Get-Content -LiteralPath $JTAG_REPORT
```

The report path must not already exist. The script requires exactly one JTAG
target and one matching `xc7k325t*` device, runs `program_hw_devices`, and
checks CRC, EOS, INIT_B, DONE, and GWE status. The two PowerShell
`Get-FileHash` calls prove that the same on-disk bitstream existed before and
after that programming command. Its lowercase hash is saved beside the bitstream
as `memblaze_k7_xdma_wrapper.bit.sha256`. The report is hashed separately as
`jtag_program_status.txt.sha256`; do not put the bitstream hash in the report
sidecar. Preserve the bitstream, report, and both sidecars for the physical
regression record. The script does not create or program a configuration-memory
device. FPGA SRAM is volatile, so configure it before the host performs PCIe
enumeration after a full power loss.

## Hardware acceptance for a new build

A successful Vivado build proves project generation, implementation checks,
and bitstream creation. Before treating a new SHA-256 as hardware-validated,
repeat the following with that exact bitstream:

1. JTAG SRAM programming and configuration-status verification.
2. Cold enumeration as PCI ID `10ee:7024`, including the active BAR resources
   reported by `lspci -vv`.
3. Secure Boot remains enabled and the freshly built, existing-MOK-signed XDMA
   module is accepted by the kernel.
4. XDMA driver binding, expected `/dev/xdma*` nodes, and all four H2C/C2H
   engine identifiers.
5. Basic H2C/C2H comparisons and a 64 MiB comparison on each channel.
6. `alias-4g` address-boundary checks.
7. `chunked-1g` data comparison.
8. Concurrent dual-channel H2C/C2H comparison.
9. Two-phase full-4-GiB comparison: write all 64 distinct 64 MiB chunks before
   reading and comparing any chunk.
10. Stable PCIe path and kernel-log evidence, AER and IRQ evidence when the
    platform exposes it, final XDMA cleanup, and a checksummed evidence bundle.

Keep build success, PCIe enumeration, driver loading, and DMA data integrity as
separate evidence.
