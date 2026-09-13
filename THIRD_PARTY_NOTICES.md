# Third-party notices

## Xilinx/AMD XDMA Linux driver

- Upstream: <https://github.com/Xilinx/dma_ip_drivers>
- Commit: `b8466090b4e812e191da9e9305ffb11cb7ace768`
- Bundled snapshot: `vendor/xdma_linux_kernel_b8466090.tar.gz`
- Extracted-source manifest: `vendor/xdma_linux_kernel_b8466090.sha256`
- Snapshot SHA-256:
  `aba9086b051e2e29ee6a38a0b655857010e75400d7c410340334938586be23a2`

The archive retains `XDMA/linux-kernel/LICENSE` and `COPYING`. Its files
remain governed by their upstream notices on a file-by-file basis. The
kernel/include files whose headers say so remain GPL-2.0-only; the userspace
tools carry the upstream BSD-style terms. Copies of the relevant license texts
are in `LICENSES/`.

`linux/patches/0001-portable-kbuild.patch` modifies the upstream driver
Makefile, which has no more-specific file header and is covered by the
directory's BSD-style license. The patch is distributed under BSD-3-Clause
and adds a dated modification notice to the resulting Makefile.

The root MIT License does not relicense any of these files.

## AMD/Xilinx design tools and IP

Vivado and AMD/Xilinx IP are external tool dependencies obtained from AMD under
their applicable terms. No design-tool installation, authorization code, or
generated IP output product is included.

The repository's build Tcl and XDC are project-authored source inputs. The
source-controlled `fpga/mig/memblaze_ddr3.prj` identifies itself as generated
by AMD/Xilinx MIG software. It is not relicensed under the root MIT License;
its use and redistribution remain subject to the applicable AMD/Xilinx tool
and IP terms. It is retained beside the design source according to AMD's
[Vivado Design Suite User Guide: Design Methodology UG949 (2026.1)](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/IP-Versions-and-Revision-Control),
which requires the PRJ file to be saved for version control of 7-series memory
IP.
Locally generated FPGA output products and bitstreams remain outside Git and
must be handled under the applicable tool and IP terms.
