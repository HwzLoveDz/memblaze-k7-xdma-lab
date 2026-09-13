# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors

# PCIe 100 MHz differential reference clock. The N pin is fixed by the MGT
# differential pair associated with U8.
set_property PACKAGE_PIN U8 [get_ports {CLK_IN_D_0_clk_p[0]}]
create_clock -name pcie_refclk_100m -period 10.000 \
    [get_ports {CLK_IN_D_0_clk_p[0]}]

# PCIe Gen2 x8 transmit lanes. The XDMA core is fixed to PCIe block X0Y0;
# generated core constraints place the matching receive lanes and GTX channels.
set_property PACKAGE_PIN L4 [get_ports {pcie_mgt_0_txp[0]}]
set_property PACKAGE_PIN M2 [get_ports {pcie_mgt_0_txp[1]}]
set_property PACKAGE_PIN N4 [get_ports {pcie_mgt_0_txp[2]}]
set_property PACKAGE_PIN P2 [get_ports {pcie_mgt_0_txp[3]}]
set_property PACKAGE_PIN T2 [get_ports {pcie_mgt_0_txp[4]}]
set_property PACKAGE_PIN U4 [get_ports {pcie_mgt_0_txp[5]}]
set_property PACKAGE_PIN V2 [get_ports {pcie_mgt_0_txp[6]}]
set_property PACKAGE_PIN Y2 [get_ports {pcie_mgt_0_txp[7]}]

# PCIe PERST#.
set_property PACKAGE_PIN V22 [get_ports sys_rst_n_0]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n_0]
set_property PULLUP true [get_ports sys_rst_n_0]

# Board clock for the 200 MHz MIG input clock generator.
set_property PACKAGE_PIN D27 [get_ports clk_in1_50M]
set_property IOSTANDARD LVCMOS18 [get_ports clk_in1_50M]

# Configuration settings are retained for compatibility with the board, but
# the public flow programs SRAM by JTAG. Pullnone prevents unused user I/O,
# including W26 and the unused J1-J4 signals, from acquiring a post-config pull.
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
