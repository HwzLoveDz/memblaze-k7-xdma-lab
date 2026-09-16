# Changelog

All notable changes to this project will be documented here.

## [0.1.0-lab] - 2026-09-16

### Added

- Repository-local Vivado 2026.1 source flow for the XC7K325T XDMA-to-DDR3
  design, including project/BD generation, board constraints, MIG configuration,
  routed checks, and volatile-SRAM programming.
- Guarded Linux scripts for PCIe probe, pinned-driver build, Secure Boot
  inspection, XDMA load verification, basic DMA, extended DDR validation, and
  cleanup.
- Linux 7.0 portable-Kbuild patch for XDMA commit `b8466090`.
- Sanitized evidence for the 2026-09-14 physical board/host campaign.
- A clean Vivado 2026.1 repository build with DRC, timing, bus-skew,
  methodology, source-set, and bitstream-hash evidence.
- English entry page and Chinese operating, troubleshooting, provenance, and
  open-items documentation.
- Static publication checks and deterministic checksum tooling.
- Native RC4 exact-image physical regression evidence: fresh XDMA build,
  Secure Boot load, basic and concurrent DMA, full 4 GiB comparison,
  post-cleanup kernel scan, and cleanup all completed with return code 0.
- Sanitized hardware, debug-session, and powered-fixture photographs plus a
  canonical wiring figure covering PCIe, M.2 3.3 V, PD-triggered 12 V, and
  JTAG paths.
- The exact dual-source power topology and the successful keep-powered
  Windows-to-Ubuntu sequence. The 12 V and 3.3 V rails are recorded as fully
  isolated in the board's power distribution with no backfeed, and the
  high-speed FPGA bank voltage as determined by the PCIe input side; remaining
  connector, current, and pin-table boundaries are
  stated explicitly.

### Fixed

- Replaced the unsupported `dmesg --time-format=raw` invocation with a shared
  kernel-log capture helper compatible with Ubuntu 24.04's util-linux 2.39.3.
  It uses plain `dmesg` first, falls back to the current-boot kernel journal,
  fixes one backend for every before/after pair, and records both return codes
  and error output when capture is unavailable.
- Added an executable regression test for kernel-log selection and diagnostics,
  and pinned the repository CI check to Ubuntu 24.04.
- Extended exact-run result-log polling to 60 seconds so child `tee` processes
  can finish flushing before the parent validates their markers.
- Preserved the exact-run arguments across the `systemd-inhibit` re-exec. The
  previous wrapper parsed and shifted all arguments before restarting itself,
  so the protected run stopped at its confirmation gate. A runtime regression
  test now captures and compares every re-exec argument.
- Excluded the XDMA module's informational `timeout: h2c ... c2h ...` parameter
  line from the final severe-kernel-message gate. Real XDMA timeout, failure,
  error, AER, allocation, and storage messages remain fatal and are covered by
  a runtime filter test. The final scan now runs after mandatory driver cleanup,
  and a filter read/error failure also fails the workflow.

### Known limits

- Validated on one physical host and adapter path; a second independent replay
  is not required for this release.
- `lspci` topology fields and the XDMA tool's single-transfer timing disagree.
  Application-level and tool-level throughput are recorded, but the result is
  not claimed as a peak physical-link characterization.
- A single monolithic 1 GiB DMA request was not validated; the public flow uses
  requests no larger than 64 MiB.
- The exact enclosure bridge, adapter revision, auxiliary connector pinout,
  PD/line current ratings, hot-plug behavior, and public JTAG pin table remain
  unknown; the release only claims the pictured and physically tested
  combination.
