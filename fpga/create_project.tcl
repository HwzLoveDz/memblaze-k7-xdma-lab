# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors
#
# Create and optionally implement the complete Memblaze K7 XDMA design.
# All build inputs are stored under fpga/.
#
# Usage:
#   vivado -mode batch -source fpga/create_project.tcl \
#     -tclargs ABSOLUTE_EMPTY_BUILD_DIR ?--write-bitstream?

proc fail {stage message code} {
    puts stderr "MEMBLAZE_BUILD_ERROR|$stage|$message"
    catch {stop_runs [get_runs -quiet]}
    catch {close_design}
    catch {close_bd_design [current_bd_design]}
    catch {close_project}
    exit $code
}

proc portable_path {path_value} {
    set mapped [string map {\\ /} $path_value]
    if {[file pathtype $mapped] eq {relative}} {
        set mapped [file join [pwd] $mapped]
    }
    return [string trimright [string map {\\ /} $mapped] /]
}

proc write_text {path_value text_value} {
    set stream [open $path_value w]
    fconfigure $stream -translation lf
    puts $stream $text_value
    close $stream
}

proc check_timing_count {category report_text} {
    # Vivado 2026.1 prints each enabled check as
    # "N. checking <category> (<count>)" in the table of contents and again
    # above the detail section. Require every parsed copy to agree. If AMD
    # changes the format, fail closed instead of silently skipping the gate.
    set pattern [format \
        {^[[:space:]]*[0-9]+[.] checking %s [(]([0-9]+)[)][[:space:]]*$} \
        $category]
    set matches [regexp -all -inline -line -- $pattern $report_text]
    if {[llength $matches] < 2 || ([llength $matches] % 2) != 0} {
        fail check_timing_parse "Could not parse category $category" 33
    }
    set counts {}
    for {set index 1} {$index < [llength $matches]} {incr index 2} {
        lappend counts [lindex $matches $index]
    }
    set unique_counts [lsort -integer -unique $counts]
    if {[llength $unique_counts] != 1} {
        fail check_timing_parse \
            "Conflicting counts for $category: [join $unique_counts ,]" 33
    }
    return [lindex $unique_counts 0]
}

proc require_report_lines {category report_text expected_lines} {
    set trimmed_lines {}
    foreach line [split $report_text "\n"] {
        lappend trimmed_lines [string trim $line]
    }
    foreach expected $expected_lines {
        if {[lsearch -exact $trimmed_lines $expected] < 0} {
            fail check_timing_allowlist \
                "Expected $category entry is absent: $expected" 34
        }
    }
}

proc initialize_install_tclstore {} {
    # Some Windows installs have a stale per-user Tcl Store that shadows the
    # complete copy shipped with Vivado. Add the install copy explicitly before
    # create_project so project initialization remains reproducible.
    if {![info exists ::env(XILINX_VIVADO)]} {
        fail tclstore {XILINX_VIVADO is not set} 2
    }
    set store_root [file join $::env(XILINX_VIVADO) data XilinxTclStore]
    if {![file isdirectory $store_root]} {
        fail tclstore "Installed Tcl Store is missing: $store_root" 2
    }
    foreach package_dir [concat \
            [glob -nocomplain -types d [file join $store_root support *]] \
            [glob -nocomplain -types d [file join $store_root tclapp * *]]] {
        if {[lsearch -exact $::auto_path $package_dir] < 0} {
            lappend ::auto_path $package_dir
        }
    }
    if {[catch {package require ::tclapp::support::appinit 1.2} appinit_error]} {
        fail tclstore "Could not load installed appinit 1.2: $appinit_error" 2
    }
}

if {$argc < 1 || $argc > 2} {
    puts stderr {Usage: create_project.tcl ABSOLUTE_EMPTY_BUILD_DIR ?--write-bitstream?}
    exit 2
}
if {[version -short] ne {2026.1}} {
    fail vivado_version "Expected Vivado 2026.1, got [version -short]" 3
}
initialize_install_tclstore

set raw_build_dir [string map {\\ /} [lindex $argv 0]]
if {[file pathtype $raw_build_dir] ne {absolute}} {
    fail arguments {Build directory must be absolute} 4
}
set build_dir [portable_path $raw_build_dir]
if {[regexp {(^|/)\.\.(/|$)} $build_dir]} {
    fail arguments {Build directory must not contain .. components} 4
}
set write_bitstream_requested 0
if {$argc == 2} {
    if {[lindex $argv 1] ne {--write-bitstream}} {
        fail arguments {The only optional argument is --write-bitstream} 4
    }
    set write_bitstream_requested 1
}

if {[file exists $build_dir]} {
    fail output_boundary "Build directory must not already exist: $build_dir" 5
}
file mkdir $build_dir

set fpga_root [file dirname [string map {\\ /} [info script]]]
set bd_script [file join $fpga_root bd create_design.tcl]
set board_xdc [file join $fpga_root constraints board.xdc]
foreach source_file [list $bd_script $board_xdc \
        [file join $fpga_root mig memblaze_ddr3.prj]] {
    if {![file isfile $source_file]} {
        fail source_missing "Missing repository input: $source_file" 6
    }
}

set project_dir [file join $build_dir p]
set report_dir [file join $build_dir reports]
file mkdir $report_dir
cd $build_dir
create_project memblaze_k7_xdma $project_dir -part xc7k325tffg900-2
set_param general.maxThreads 4

if {[catch {source $bd_script} bd_error]} {
    fail create_bd $bd_error 10
}
set bd_files [get_files -quiet */memblaze_k7_xdma.bd]
if {[llength $bd_files] != 1} {
    fail create_bd "Expected one block design, found [llength $bd_files]" 10
}
set bd_file [lindex $bd_files 0]

add_files -fileset constrs_1 -norecurse $board_xdc
set_property USED_IN_SYNTHESIS true [get_files $board_xdc]
set_property USED_IN_IMPLEMENTATION true [get_files $board_xdc]

if {[catch {validate_bd_design -force} validate_error]} {
    fail validate_bd_design $validate_error 11
}
save_bd_design

set locked_ips [get_ips -all -quiet -filter {IS_LOCKED == 1}]
if {[llength $locked_ips] != 0} {
    fail locked_ips "Locked IP remains: [join $locked_ips ,]" 12
}
set upgradeable_ips {}
foreach ip [get_ips -all -quiet] {
    if {[string length [get_property UPGRADE_VERSIONS $ip]] > 0} {
        lappend upgradeable_ips $ip
    }
}
if {[llength $upgradeable_ips] != 0} {
    fail upgradeable_ips "Upgrade remains available: [join $upgradeable_ips ,]" 13
}
write_text [file join $report_dir ip_status.txt] [report_ip_status -return_string]

if {[catch {generate_target all $bd_file} generate_error]} {
    fail generate_target $generate_error 14
}
set wrapper_files [make_wrapper -files $bd_file -top]
if {[llength $wrapper_files] != 1} {
    fail wrapper "Expected one generated wrapper, found [llength $wrapper_files]" 15
}
add_files -norecurse [lindex $wrapper_files 0]
set_property top memblaze_k7_xdma_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Record machine-readable source configuration before implementation.
open_bd_design $bd_file
write_text [file join $report_dir bd_cells.txt] \
    [join [lsort [get_property NAME [get_bd_cells -hierarchical]]] \n]
set address_lines {}
foreach segment [get_bd_addr_segs -hierarchical] {
    set offset [get_property -quiet OFFSET $segment]
    set range [get_property -quiet RANGE $segment]
    lappend address_lines "$segment|OFFSET=$offset|RANGE=$range"
}
write_text [file join $report_dir bd_address_map.txt] [join $address_lines \n]
close_bd_design [current_bd_design]

if {!$write_bitstream_requested} {
    close_project
    puts "MEMBLAZE_CREATE_OK|project|$project_dir"
    puts "MEMBLAZE_CREATE_OK|reports|$report_dir"
    exit 0
}

if {[catch {launch_runs synth_1 -jobs 4} launch_synth_error]} {
    fail launch_synth $launch_synth_error 20
}
if {[catch {wait_on_run synth_1} wait_synth_error]} {
    fail wait_synth $wait_synth_error 21
}
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match {*Complete*} $synth_status]} {
    fail synth_status $synth_status 22
}
open_run synth_1 -name synth_1
report_utilization -file [file join $report_dir synth_utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir synth_timing_summary.rpt]
report_drc -file [file join $report_dir synth_drc.rpt]
report_io -file [file join $report_dir synth_io.rpt]
close_design

if {[catch {launch_runs impl_1 -to_step route_design -jobs 4} launch_impl_error]} {
    fail launch_impl $launch_impl_error 23
}
if {[catch {wait_on_run impl_1} wait_impl_error]} {
    fail wait_impl $wait_impl_error 24
}
set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match {*Complete*} $impl_status]} {
    fail impl_status $impl_status 25
}
open_run impl_1 -name impl_1

report_route_status -file [file join $report_dir impl_route_status.rpt]
report_drc -file [file join $report_dir impl_drc.rpt]
report_methodology -file [file join $report_dir impl_methodology.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir impl_timing_summary.rpt]
report_clock_interaction -delay_type min_max \
    -file [file join $report_dir impl_clock_interaction.rpt]
report_utilization -file [file join $report_dir impl_utilization.rpt]
report_io -file [file join $report_dir impl_io.rpt]

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} {
    fail impl_drc "DRC errors remain: [join $drc_errors ,]" 26
}

if {[catch {check_timing -verbose -return_string} check_timing_text]} {
    fail check_timing_report $check_timing_text 33
}
write_text [file join $report_dir impl_check_timing.rpt] $check_timing_text

# These categories indicate missing clocks, ambiguous clocking, combinational
# feedback, or incompletely constrained internal timing. Every count must be
# present in the pinned Vivado 2026.1 report and must be zero.
set zero_timing_checks {
    no_clock
    constant_clock
    generated_clocks
    latch_loops
    loops
    multiple_clock
    unconstrained_internal_endpoints
    partial_input_delay
    partial_output_delay
}
set timing_check_status {}
set nonzero_timing_checks {}
foreach category $zero_timing_checks {
    set count [check_timing_count $category $check_timing_text]
    lappend timing_check_status "CheckTiming_${category}=$count"
    if {$count != 0} {
        lappend nonzero_timing_checks "$category=$count"
    }
}

# MIG source-synchronous DQS inputs and its DDR3 reset output intentionally use
# the controller's generated interface constraints rather than board-level
# set_input_delay/set_output_delay constraints. PERST# is asynchronous. Check
# both the exact 2026.1 counts and every expected report line, so unrelated
# unconstrained ports cannot be hidden by these narrow exceptions.
set expected_no_input_delay_ports [list \
    {DDR3_0_dqs_p[0]} \
    {DDR3_0_dqs_p[1]} \
    {DDR3_0_dqs_p[2]} \
    {DDR3_0_dqs_p[3]} \
    {DDR3_0_dqs_p[4]} \
    {DDR3_0_dqs_p[5]} \
    {DDR3_0_dqs_p[6]} \
    {DDR3_0_dqs_p[7]} \
    {sys_rst_n_0}]
set expected_no_output_delay_ports [list {DDR3_0_reset_n}]
set no_input_delay_count [check_timing_count no_input_delay $check_timing_text]
set no_output_delay_count [check_timing_count no_output_delay $check_timing_text]
require_report_lines no_input_delay $check_timing_text $expected_no_input_delay_ports
require_report_lines no_output_delay $check_timing_text $expected_no_output_delay_ports
if {$no_input_delay_count != [llength $expected_no_input_delay_ports]} {
    lappend nonzero_timing_checks \
        "no_input_delay=$no_input_delay_count expected=[llength $expected_no_input_delay_ports]"
}
if {$no_output_delay_count != [llength $expected_no_output_delay_ports]} {
    lappend nonzero_timing_checks \
        "no_output_delay=$no_output_delay_count expected=[llength $expected_no_output_delay_ports]"
}
lappend timing_check_status "CheckTiming_no_input_delay=$no_input_delay_count"
lappend timing_check_status "CheckTiming_no_output_delay=$no_output_delay_count"

# XDMA's eight GTXE2 lanes each report the same LOW-severity CLKRSVD[0]
# pulse-width advisory. Freeze both the count and all eight lane suffixes so a
# different clock problem cannot be hidden behind this documented core detail.
set pulse_width_clock_count \
    [check_timing_count pulse_width_clock $check_timing_text]
if {$pulse_width_clock_count != 8} {
    lappend nonzero_timing_checks \
        "pulse_width_clock=$pulse_width_clock_count expected=8"
}
for {set lane 0} {$lane < 8} {incr lane} {
    set expected_lane_suffix [format \
        {pipe_lane[%d].gt_wrapper_i/gtx_channel.gtxe2_channel_i/CLKRSVD[0]} \
        $lane]
    if {[string first $expected_lane_suffix $check_timing_text] < 0} {
        fail check_timing_allowlist \
            "Expected pulse_width_clock entry is absent: $expected_lane_suffix" 34
    }
}
lappend timing_check_status \
    "CheckTiming_pulse_width_clock=$pulse_width_clock_count"

if {[llength $nonzero_timing_checks] != 0} {
    fail check_timing_gate \
        "Unexpected timing-check results: [join $nonzero_timing_checks {, }]" 35
}

# The clocking-wizard scoped XDC creates the 50 MHz primary clock. Verify that
# it reaches the repository's top-level board-clock port exactly once and with
# the requested 20 ns period; adding another create_clock here would duplicate
# the IP-generated clock.
set clock50_port [get_ports -quiet clk_in1_50M]
if {[llength $clock50_port] != 1} {
    fail clock50 "Expected one clk_in1_50M port, found [llength $clock50_port]" 36
}
set clock50_objects [get_clocks -quiet -of_objects $clock50_port]
if {[llength $clock50_objects] != 1} {
    fail clock50 \
        "Expected one clock on clk_in1_50M, found [llength $clock50_objects]" 36
}
set clock50_name [get_property NAME [lindex $clock50_objects 0]]
set clock50_period [get_property PERIOD [lindex $clock50_objects 0]]
if {![regexp {^[+]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[eE][-+]?[0-9]+)?$} \
        $clock50_period] || abs($clock50_period - 20.0) > 0.001} {
    fail clock50 "Expected 20.000 ns, got $clock50_period" 36
}

set setup_paths [get_timing_paths -quiet -no_report_unconstrained \
    -setup -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -quiet -no_report_unconstrained \
    -hold -max_paths 1 -nworst 1]
if {[llength $setup_paths] != 1 || [llength $hold_paths] != 1} {
    fail timing_paths {Could not obtain one setup and one hold timing path} 27
}
set setup_wns [get_property SLACK [lindex $setup_paths 0]]
set hold_whs [get_property SLACK [lindex $hold_paths 0]]
set finite_slack_re \
    {^[-+]?(?:[0-9]+(?:[.][0-9]*)?|[.][0-9]+)(?:[eE][-+]?[0-9]+)?$}
if {![regexp $finite_slack_re $setup_wns] || \
    ![regexp $finite_slack_re $hold_whs]} {
    fail timing "Non-finite slack: setup=$setup_wns hold=$hold_whs" 28
}
if {$setup_wns < 0.0 || $hold_whs < 0.0} {
    fail timing "Negative slack: setup=$setup_wns hold=$hold_whs" 28
}

if {[catch {report_bus_skew -sort_by_slack -warn_on_violation -return_string} \
        bus_skew_text]} {
    fail bus_skew_report $bus_skew_text 29
}
write_text [file join $report_dir impl_bus_skew.rpt] $bus_skew_text
set bus_skew_count 0
set bus_skew_violation_count 0
set bus_skew_slacks {}
set bus_skew_line_re {^[ \t]*Slack[ \t]+\((MET|VIOLATED)\)[ \t]*:[ \t]*([-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+))[ \t]*ns}
foreach line [split $bus_skew_text "\n"] {
    if {[regexp -nocase $bus_skew_line_re $line -> state slack]} {
        incr bus_skew_count
        lappend bus_skew_slacks $slack
        if {[string equal -nocase $state VIOLATED] || $slack < 0.0} {
            incr bus_skew_violation_count
        }
    }
}
if {$bus_skew_count == 0 || $bus_skew_violation_count != 0} {
    fail bus_skew "evaluated=$bus_skew_count violations=$bus_skew_violation_count" 30
}
set minimum_bus_skew_slack [lindex [lsort -real $bus_skew_slacks] 0]

set bitstream_file [file join $build_dir memblaze_k7_xdma_wrapper.bit]
if {[catch {write_bitstream -force $bitstream_file} bit_error]} {
    fail write_bitstream $bit_error 31
}
if {![file isfile $bitstream_file] || [file size $bitstream_file] <= 0} {
    fail bitstream_file "Bitstream was not produced: $bitstream_file" 32
}

set status_lines [list \
    "Vivado=[version -short]" \
    "Part=[get_property PART [current_design]]" \
    "Top=[get_property TOP [current_fileset]]" \
    "SynthesisStatus=$synth_status" \
    "ImplementationStatus=$impl_status" \
    "SetupWNS=$setup_wns" \
    "HoldWHS=$hold_whs" \
    "DRCErrorCount=[llength $drc_errors]" \
    "Clock50Name=$clock50_name" \
    "Clock50PeriodNs=$clock50_period" \
    {*}$timing_check_status \
    "BusSkewConstraintCount=$bus_skew_count" \
    "BusSkewViolationCount=$bus_skew_violation_count" \
    "MinimumBusSkewSlack=$minimum_bus_skew_slack" \
    "Bitstream=$bitstream_file"]
write_text [file join $report_dir build_status.txt] [join $status_lines \n]

close_design
close_project
puts "MEMBLAZE_BUILD_OK|project|$project_dir"
puts "MEMBLAZE_BUILD_OK|reports|$report_dir"
puts "MEMBLAZE_BUILD_OK|bitstream|$bitstream_file"
exit 0
