# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors
#
# Stable public entry point. create_project.tcl contains the implementation and
# also initializes the Vivado-installed Tcl Store before create_project.

set fpga_root [file dirname [string map {\\ /} [info script]]]
source [file join $fpga_root create_project.tcl]
