# Hardware images

The public hardware record uses one canonical wiring figure plus three
sanitized photographs:

| File | Purpose |
|---|---|
| `wiring-overview.svg` | Data, 3.3 V, 12 V, and JTAG topology |
| `hardware-parts-overview.jpg` | Powered-off overview of the physical parts used |
| `xdma-debug-session.jpg` | Native-Ubuntu 64 MiB chunked C2H readback and comparison in progress |
| `hardware-running.jpg` | Powered test setup; background device identifiers are redacted |

The JPEG files were re-encoded without EXIF metadata.

The wiring figure records the user-confirmed topology:

- the Thunderbolt/USB4 enclosure supplies PCIe and 3.3 V through M.2;
- a separate USB-C PD source and trigger module, configured and negotiated to
  12 V in this setup, feed the adapter's auxiliary +12 V and return/GND input;
- both rails were stable before JTAG SRAM configuration and remained present
  from Windows through the reboot and Ubuntu regression;
- J1–J4 remain externally undriven and W26 remains high-impedance.

The 12 V and 3.3 V power rails are confirmed fully isolated in the board's
power distribution with no backfeed, and the board's high-speed FPGA bank
voltage is determined by the PCIe input side.
