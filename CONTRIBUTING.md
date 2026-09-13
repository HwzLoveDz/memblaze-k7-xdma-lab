# Contributing

Reports are most useful when they keep the evidence gates separate.

For a bring-up report, include:

1. board revision and a redacted connection description;
2. host, operating system, kernel, Vivado version, and driver commit;
3. exact `lspci -Dnn` identity and `lspci -Dvvnn` link state;
4. whether Secure Boot is enabled and whether the module actually loaded;
5. the test size, address, channel, return codes, hashes, and compare result;
6. relevant new kernel messages and the final cleanup result.

Do not attach private MOK keys, personal paths, host serials, USB/JTAG serials,
emails, BitLocker material, proprietary Vivado output products, or a
third-party bitstream.

Changes to destructive DDR tests must retain an explicit confirmation flag,
size/address bounds, endpoint ownership checks, timeouts, before/after
evidence, and cleanup behavior. New code should include an SPDX identifier and
pass `python3 tools/validate_repo.py` plus the following syntax check:

```bash
for script in linux/*.sh; do bash -n "$script"; done
```

Changes to FPGA Tcl, XDC, or MIG inputs must build from a clean output
directory. Record the generated bitstream SHA-256, and do not call the change
physically validated until that exact file passes JTAG, enumeration, driver,
DMA, extended DDR, and cleanup gates.

After the exact-image regression and final wiring image are in place, finish
the release evidence, documentation, and manifest first. Then generate and
verify the deterministic checksum manifest before running the strict release
check (the strict check itself requires a current `SHA256SUMS.txt`):

```bash
python3 tools/generate_sha256s.py
python3 tools/generate_sha256s.py --check
python3 tools/validate_repo.py --release
```
