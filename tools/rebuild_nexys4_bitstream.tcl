# Rebuild the Nexys4 DDR bitstream from the checked-in Vivado project.
#
# Usage:
#   vivado -mode batch -source tools/rebuild_nexys4_bitstream.tcl
#
# Optional:
#   VIVADO_JOBS=16 vivado -mode batch -source tools/rebuild_nexys4_bitstream.tcl

proc fail {message} {
    puts stderr $message
    exit 1
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ".."]]
set project_file [file join $repo_root "vivado" "test-cpu" "project" "project_1.xpr"]

if {![file exists $project_file]} {
    fail "Vivado project not found: $project_file"
}

if {[info exists ::env(VIVADO_JOBS)] && [string is integer -strict $::env(VIVADO_JOBS)] && $::env(VIVADO_JOBS) > 0} {
    set jobs $::env(VIVADO_JOBS)
} else {
    set jobs 8
}

open_project $project_file

set synth_run [get_runs synth_1]
set impl_run [get_runs impl_1]
if {[llength $synth_run] != 1} {
    fail "Expected one synth_1 run"
}
if {[llength $impl_run] != 1} {
    fail "Expected one impl_1 run"
}

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match "*Complete*" $synth_status]} {
    fail "synth_1 did not complete successfully: $synth_status"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*write_bitstream Complete*" $impl_status]} {
    fail "impl_1 did not complete bitstream generation: $impl_status"
}

set bitstream [file join [get_property DIRECTORY [get_runs impl_1]] "basys3_top.bit"]
if {![file exists $bitstream]} {
    fail "Bitstream was not generated: $bitstream"
}

puts "Nexys4 DDR bitstream rebuilt:"
puts "  $bitstream"
puts "Run this before board programming:"
puts "  make test-labplus-vivado-precheck"
