# Program a connected Nexys4 DDR-compatible Artix-7 device with the current bitstream.
#
# Usage:
#   vivado -mode batch -source tools/program_nexys4_bitstream.tcl
#
# Optional:
#   BITSTREAM=/path/to/basys3_top.bit vivado -mode batch -source tools/program_nexys4_bitstream.tcl
#   HW_TARGET=*/xilinx_tcf/Digilent/* vivado -mode batch -source tools/program_nexys4_bitstream.tcl

proc fail {message} {
    puts stderr $message
    exit 1
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ".."]]

if {[info exists ::env(BITSTREAM)] && $::env(BITSTREAM) ne ""} {
    set bitstream [file normalize $::env(BITSTREAM)]
} else {
    set bitstream [file join $repo_root "vivado" "test-cpu" "project" "project_1.runs" "impl_1" "basys3_top.bit"]
}

if {![file exists $bitstream]} {
    fail "Bitstream not found: $bitstream"
}

open_hw_manager
connect_hw_server

set targets [get_hw_targets]
if {[llength $targets] == 0} {
    fail "No Vivado hardware targets found"
}

if {[info exists ::env(HW_TARGET)] && $::env(HW_TARGET) ne ""} {
    set selected_targets [get_hw_targets $::env(HW_TARGET)]
    if {[llength $selected_targets] == 0} {
        fail "Requested HW_TARGET did not match any target: $::env(HW_TARGET)"
    }
    current_hw_target [lindex $selected_targets 0]
} else {
    current_hw_target [lindex $targets 0]
}

open_hw_target

set devices [get_hw_devices xc7a100t*]
if {[llength $devices] == 0} {
    set devices [get_hw_devices]
}
if {[llength $devices] == 0} {
    fail "No programmable hardware devices found"
}

set device [lindex $devices 0]
current_hw_device $device
refresh_hw_device $device

set_property PROGRAM.FILE $bitstream $device
program_hw_devices $device
refresh_hw_device $device

puts "Programmed Nexys4 DDR bitstream:"
puts "  device: $device"
puts "  bitstream: $bitstream"
