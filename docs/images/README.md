# Hardware image checklist

The public wiring image is still missing. Before the first push, place exactly
one original image here as `wiring-overview.png`, `.jpg`, `.jpeg`,
`.webp`, or `.svg`. Remove EXIF metadata and visible device serials.

Required callouts:

- board and adapter orientation;
- exact board marking/revision, FPGA part, and populated DDR3 markings/count;
- enclosure/bridge, M.2-to-PCIe adapter, cable, PSU, and JTAG model/revision;
- external 12 V polarity and ground;
- PSU current rating, measured startup/steady current, and bench current limit;
- power-source isolation/backfeed boundary;
- JTAG Pin 1, Vref, and cable direction;
- heatsink, fan, airflow direction, and fan power source;
- J1–J4 left undriven and W26 high-impedance.

The image must agree with powered-off continuity and resistance measurements.
A drawn boundary alone is not proof that the enclosure/M.2 supply and external
12 V cannot backfeed one another.
