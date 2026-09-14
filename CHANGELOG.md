# Changelog

All notable changes to this project will be documented here.

## [0.1.0-lab] - Unreleased

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

### Release blockers

- Run the exact clean-build bitstream through JTAG, enumeration, driver, DMA, extended
  DDR, and cleanup gates on the validated board.
- Add and review the original hardware wiring figure, including the measured
  power-source isolation/backfeed boundary.
- Add the physical-regression evidence, update the manifest, then generate and
  verify `SHA256SUMS.txt`.

### Known limits

- Validated on one physical host and adapter path; a second independent replay
  is not required for this release.
- `lspci` topology fields and the XDMA tool's single-transfer timing disagree;
  end-to-end throughput has not been characterized.
- A single monolithic 1 GiB DMA request was not validated; the public flow uses
  requests no larger than 64 MiB.
