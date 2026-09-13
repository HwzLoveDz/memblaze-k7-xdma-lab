## Change

Describe the final behavior and the specific problem it solves.

## Evidence

- [ ] `python3 tools/validate_repo.py --release` passes for a release-ready tree
- [ ] `python3 tools/generate_sha256s.py --check` passes
- [ ] `for script in linux/*.sh; do bash -n "$script"; done` passes
- [ ] New hardware claims include conditions and redacted raw evidence
- [ ] Enumeration, driver binding, and DMA comparison are reported separately
- [ ] FPGA source changes build from a clean output directory
- [ ] The exact bitstream SHA-256 is linked across build, JTAG, and physical regression evidence
- [ ] No generated bitstream/IP output, private key, personal path, or device serial was added

## Hardware impact

State whether the change writes FPGA DDR, programs volatile SRAM, changes an
external IO, or is documentation/static analysis only.
