# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Memblaze K7 XDMA Lab contributors
#
# Program one XC7K325T over JTAG. This script writes FPGA SRAM only.
# Usage:
#   vivado -mode batch -source C:/work/memblaze-k7-xdma-lab/fpga/program_sram.tcl \
#          -tclargs C:/work/mb2/memblaze_k7_xdma_wrapper.bit C:/work/mb2/jtag_program_status.txt

if {$argc < 1 || $argc > 3} {
    puts stderr {Usage: program_sram.tcl BIT_FILE ?REPORT_FILE? ?DEVICE_GLOB?}
    exit 2
}

proc resolve_cli_path {path_arg} {
    # Vivado 2026.1 on Windows can mis-normalize a valid path below the user's
    # Desktop. Keep an absolute CLI path intact and only make separators Tcl-safe.
    set mapped [string map {\\ /} $path_arg]
    if {[file pathtype $mapped] eq {relative}} {
        puts stderr "JTAG_PROGRAM_ERROR=Path must be absolute: $path_arg"
        exit 2
    }
    return $mapped
}

set bit_file [resolve_cli_path [lindex $argv 0]]
if {$argc >= 2} {
    set report_file [resolve_cli_path [lindex $argv 1]]
} else {
    set report_file [file join [file dirname $bit_file] jtag_program_status.txt]
}
if {$argc >= 3} {
    set device_glob [lindex $argv 2]
} else {
    set device_glob {xc7k325t*}
}

if {![file isfile $bit_file]} {
    puts stderr "JTAG_PROGRAM_ERROR=Bitstream does not exist: $bit_file"
    exit 2
}
set bit_file_compare [string tolower [string trimright [string map {\\ /} $bit_file] /]]
set report_file_compare [string tolower [string trimright [string map {\\ /} $report_file] /]]
if {$bit_file_compare eq $report_file_compare} {
    puts stderr {JTAG_PROGRAM_ERROR=REPORT_FILE must not be the bitstream path}
    exit 2
}
if {[file exists $report_file]} {
    puts stderr "JTAG_PROGRAM_ERROR=Report already exists; choose a new path: $report_file"
    exit 2
}

set report_parent [file dirname $report_file]
if {![file isdirectory $report_parent]} {
    file mkdir $report_parent
}

set fh [open $report_file w]
set exit_code 0
puts $fh "Bitstream=$bit_file"
puts $fh "BitstreamBytes=[file size $bit_file]"
puts $fh "DeviceGlob=$device_glob"
puts $fh "StartedAt=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"

if {[catch {
    open_hw_manager
    connect_hw_server -allow_non_jtag
    set targets [get_hw_targets]
    if {[llength $targets] != 1} {
        error "Expected exactly one JTAG target; found [llength $targets]"
    }

    set target [lindex $targets 0]
    current_hw_target $target
    open_hw_target

    set matching_devices {}
    foreach candidate [get_hw_devices] {
        if {[string match -nocase $device_glob [get_property PART $candidate]]} {
            lappend matching_devices $candidate
        }
    }
    if {[llength $matching_devices] != 1} {
        error "Expected exactly one device matching $device_glob; found [llength $matching_devices]"
    }

    set dev [lindex $matching_devices 0]
    current_hw_device $dev
    puts $fh "Target=$target"
    puts $fh "Device=$dev"
    puts $fh "Part=[get_property PART $dev]"
    set_property PROGRAM.FILE $bit_file $dev

    puts "PROGRAMMING_DEVICE=$dev"
    program_hw_devices $dev
    after 2000
    refresh_hw_device -update_hw_probes false $dev

    puts $fh {ProgramCommand=completed}
    foreach prop [lsort [list_property $dev]] {
        if {[string match {REGISTER.CONFIG_STATUS*} $prop] ||
            [string match {REGISTER.BOOT_STATUS*} $prop] ||
            [string match {REGISTER.IR_STATUS*} $prop] ||
            [string match {PROGRAM.*} $prop] ||
            $prop eq {PART}} {
            if {![catch {get_property $prop $dev} value]} {
                puts $fh "$prop=$value"
            }
        }
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT00_CRC_ERROR $dev] ne {0}} {
        error {CRC_ERROR asserted after programming}
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS $dev] ne {1}} {
        error {EOS is not high after programming}
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT11_INIT_B_INTERNAL_SIGNAL_STATUS $dev] ne {1}} {
        error {INIT_B is not high after programming}
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT13_DONE_INTERNAL_SIGNAL_STATUS $dev] ne {1}} {
        error {internal DONE is not high after programming}
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev] ne {1}} {
        error {DONE pin is not high after programming}
    }
    if {[get_property REGISTER.CONFIG_STATUS.BIT06_GWE_STATUS $dev] ne {1}} {
        error {GWE is not high after programming}
    }
    puts $fh {Verification=PASS}
    puts $fh "FinishedAt=[clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
} message]} {
    puts stderr "JTAG_PROGRAM_ERROR=$message"
    puts $fh "Error=$message"
    set exit_code 1
}

catch {close_hw_target}
catch {disconnect_hw_server}
catch {close_hw_manager}
close $fh

if {$exit_code == 0} {
    puts {JTAG_PROGRAM_AND_VERIFY_OK}
    puts "JTAG_REPORT=$report_file"
}
exit $exit_code
