# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors
#
# Create the Memblaze Kintex-7 XDMA-to-DDR3 block design from source inputs in
# this repository. The caller must open a project for xc7k325tffg900-2 first.

namespace eval ::memblaze_bd {
    variable design_name {memblaze_k7_xdma}

    proc fail {message} {
        error "MEMBLAZE_BD_ERROR|$message"
    }

    proc require_ip {vlnv} {
        if {[llength [get_ipdefs -all -quiet $vlnv]] == 0} {
            fail "Required IP is unavailable: $vlnv"
        }
    }

    proc create {} {
        variable design_name

        if {[llength [get_projects -quiet]] != 1} {
            fail {Exactly one Vivado project must be open}
        }
        if {[get_property PART [current_project]] ne {xc7k325tffg900-2}} {
            fail "Expected xc7k325tffg900-2, got [get_property PART [current_project]]"
        }
        if {[llength [get_bd_designs -quiet $design_name]] != 0 ||
            [llength [get_files -quiet */${design_name}.bd]] != 0} {
            fail "Block design already exists: $design_name"
        }

        foreach vlnv {
            xilinx.com:ip:util_ds_buf:2.2
            xilinx.com:ip:xdma:4.2
            xilinx.com:ip:mig_7series:4.2
            xilinx.com:ip:clk_wiz:6.0
            xilinx.com:ip:xlconstant:1.1
            xilinx.com:ip:axi_interconnect:2.1
            xilinx.com:ip:proc_sys_reset:5.0
        } {
            require_ip $vlnv
        }

        create_bd_design $design_name
        current_bd_design $design_name

        set pcie_refclk [create_bd_intf_port -mode Slave \
            -vlnv xilinx.com:interface:diff_clock_rtl:1.0 CLK_IN_D_0]
        set_property CONFIG.FREQ_HZ {100000000} $pcie_refclk
        create_bd_intf_port -mode Master \
            -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pcie_mgt_0
        create_bd_intf_port -mode Master \
            -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR3_0

        set pcie_reset [create_bd_port -dir I -type rst sys_rst_n_0]
        set_property CONFIG.POLARITY {ACTIVE_LOW} $pcie_reset
        create_bd_port -dir I -type clk -freq_hz 50000000 clk_in1_50M

        set refclk_buf [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0]
        set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $refclk_buf

        set xdma [create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.2 xdma_0]
        # Values that define the host-visible endpoint and the tested DMA path
        # are explicit here. Do not rely on Vivado IP defaults for these fields.
        set_property -dict [list \
            CONFIG.functional_mode {DMA} \
            CONFIG.mode_selection {Advanced} \
            CONFIG.device_port_type {PCI_Express_Endpoint_device} \
            CONFIG.pcie_blk_locn {X0Y0} \
            CONFIG.pl_link_cap_max_link_width {X8} \
            CONFIG.pl_link_cap_max_link_speed {5.0_GT/s} \
            CONFIG.ref_clk_freq {100_MHz} \
            CONFIG.axi_addr_width {64} \
            CONFIG.axi_data_width {128_bit} \
            CONFIG.axi_id_width {4} \
            CONFIG.axisten_freq {250} \
            CONFIG.en_axi_master_if {true} \
            CONFIG.dedicate_perst {true} \
            CONFIG.sys_reset_polarity {ACTIVE_LOW} \
            CONFIG.vendor_id {10EE} \
            CONFIG.pf0_device_id {7024} \
            CONFIG.pf0_revision_id {00} \
            CONFIG.pf0_subsystem_vendor_id {10EE} \
            CONFIG.pf0_subsystem_id {0007} \
            CONFIG.pf0_Use_Class_Code_Lookup_Assistant {false} \
            CONFIG.pf0_class_code_base {05} \
            CONFIG.pf0_class_code_sub {80} \
            CONFIG.pf0_class_code_interface {00} \
            CONFIG.pf0_bar0_enabled {true} \
            CONFIG.pf0_bar0_type {Memory} \
            CONFIG.pf0_bar0_size {128} \
            CONFIG.pf0_bar0_scale {Kilobytes} \
            CONFIG.pf0_bar0_64bit {false} \
            CONFIG.pf0_bar0_prefetchable {false} \
            CONFIG.pf0_bar0_index {0} \
            CONFIG.pf0_bar1_enabled {false} \
            CONFIG.pf0_bar1_index {7} \
            CONFIG.pf0_bar2_enabled {false} \
            CONFIG.pf0_bar2_index {7} \
            CONFIG.pf0_bar3_enabled {false} \
            CONFIG.pf0_bar3_index {7} \
            CONFIG.pf0_bar4_enabled {false} \
            CONFIG.pf0_bar4_index {7} \
            CONFIG.pf0_bar5_enabled {false} \
            CONFIG.pf0_bar5_index {7} \
            CONFIG.xdma_size {64} \
            CONFIG.xdma_scale {Kilobytes} \
            CONFIG.bar_indicator {BAR_0} \
            CONFIG.bar0_indicator {1} \
            CONFIG.bar1_indicator {0} \
            CONFIG.bar2_indicator {0} \
            CONFIG.bar3_indicator {0} \
            CONFIG.bar4_indicator {0} \
            CONFIG.bar5_indicator {0} \
            CONFIG.barlite2 {7} \
            CONFIG.pciebar2axibar_xdma {0x0000000000000000} \
            CONFIG.pf0_msi_enabled {true} \
            CONFIG.pf0_msi_cap_multimsgcap {1_vector} \
            CONFIG.pf0_msix_enabled {false} \
            CONFIG.axilite_master_en {false} \
            CONFIG.axist_bypass_en {false} \
            CONFIG.xdma_axilite_slave {false} \
            CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
            CONFIG.xdma_rnum_chnl {2} \
            CONFIG.xdma_wnum_chnl {2} \
            CONFIG.xdma_num_usr_irq {1} \
            CONFIG.xdma_rnum_rids {32} \
            CONFIG.xdma_wnum_rids {16} \
            CONFIG.enable_gen4 {false} \
            CONFIG.enable_gtwizard {false} \
            CONFIG.plltype {QPLL1} \
            CONFIG.runbit_fix {false} \
            CONFIG.pcie_extended_tag {true} \
            CONFIG.pf0_link_status_slot_clock_config {true} \
        ] $xdma

        set mig [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:mig_7series:4.2 mig_7series_0]
        set fpga_root [file dirname [file dirname [string map {\\ /} [info script]]]]
        set mig_source [file join $fpga_root mig memblaze_ddr3.prj]
        if {![file isfile $mig_source]} {
            fail "MIG configuration is missing: $mig_source"
        }
        set mig_ip [get_ips [get_property CONFIG.Component_Name $mig]]
        set mig_ip_dir [get_property IP_DIR $mig_ip]
        file mkdir $mig_ip_dir
        file copy -force $mig_source [file join $mig_ip_dir memblaze_ddr3.prj]
        set_property -dict [list \
            CONFIG.BOARD_MIG_PARAM {Custom} \
            CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
            CONFIG.RESET_BOARD_INTERFACE {Custom} \
            CONFIG.XML_INPUT_FILE {memblaze_ddr3.prj} \
        ] $mig

        set ddr_clock [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
        set_property -dict [list \
            CONFIG.CLKIN1_JITTER_PS {200.0} \
            CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {200.000} \
            CONFIG.CLK_OUT1_PORT {clk_200M} \
            CONFIG.MMCM_CLKFBOUT_MULT_F {20.000} \
            CONFIG.MMCM_CLKIN1_PERIOD {20.000} \
            CONFIG.MMCM_CLKOUT0_DIVIDE_F {5.000} \
            CONFIG.PRIM_IN_FREQ {50.000} \
            CONFIG.USE_RESET {false} \
        ] $ddr_clock

        set reset_one [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0]
        set_property -dict [list CONFIG.CONST_VAL {1} CONFIG.CONST_WIDTH {1}] $reset_one

        set interconnect [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_mem_intercon]
        set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $interconnect

        set reset_sync [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_mig_7series_0_200M]

        connect_bd_intf_net [get_bd_intf_ports CLK_IN_D_0] \
            [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
        connect_bd_intf_net [get_bd_intf_ports pcie_mgt_0] \
            [get_bd_intf_pins xdma_0/pcie_mgt]
        connect_bd_intf_net [get_bd_intf_ports DDR3_0] \
            [get_bd_intf_pins mig_7series_0/DDR3]
        connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] \
            [get_bd_intf_pins axi_mem_intercon/S00_AXI]
        connect_bd_intf_net [get_bd_intf_pins axi_mem_intercon/M00_AXI] \
            [get_bd_intf_pins mig_7series_0/S_AXI]

        connect_bd_net [get_bd_ports clk_in1_50M] [get_bd_pins clk_wiz_0/clk_in1]
        connect_bd_net [get_bd_pins clk_wiz_0/clk_200M] \
            [get_bd_pins mig_7series_0/sys_clk_i]
        connect_bd_net [get_bd_pins mig_7series_0/mmcm_locked] \
            [get_bd_pins rst_mig_7series_0_200M/dcm_locked]
        connect_bd_net [get_bd_pins mig_7series_0/ui_clk] \
            [get_bd_pins axi_mem_intercon/M00_ACLK] \
            [get_bd_pins rst_mig_7series_0_200M/slowest_sync_clk]
        connect_bd_net [get_bd_pins mig_7series_0/ui_clk_sync_rst] \
            [get_bd_pins rst_mig_7series_0_200M/ext_reset_in]
        connect_bd_net [get_bd_pins rst_mig_7series_0_200M/peripheral_aresetn] \
            [get_bd_pins axi_mem_intercon/M00_ARESETN] \
            [get_bd_pins mig_7series_0/aresetn]
        connect_bd_net [get_bd_ports sys_rst_n_0] [get_bd_pins xdma_0/sys_rst_n]
        connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins xdma_0/sys_clk]
        connect_bd_net [get_bd_pins xdma_0/axi_aclk] \
            [get_bd_pins axi_mem_intercon/ACLK] \
            [get_bd_pins axi_mem_intercon/S00_ACLK]
        connect_bd_net [get_bd_pins xdma_0/axi_aresetn] \
            [get_bd_pins axi_mem_intercon/ARESETN] \
            [get_bd_pins axi_mem_intercon/S00_ARESETN]
        connect_bd_net [get_bd_pins xlconstant_0/dout] [get_bd_pins mig_7series_0/sys_rst]

        # The design intentionally exposes the whole 32-bit DDR address space.
        # A build-ID register cannot share this space without shrinking or
        # remapping DDR, so it is deferred until a separate PCIe BAR is designed.
        assign_bd_address -offset 0x00000000 -range 0x000100000000 \
            -target_address_space [get_bd_addr_spaces xdma_0/M_AXI] \
            [get_bd_addr_segs mig_7series_0/memmap/memaddr] -force

        validate_bd_design -force
        save_bd_design
        return [get_files */${design_name}.bd]
    }
}

::memblaze_bd::create
