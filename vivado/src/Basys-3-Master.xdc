## Minimal constraints for Nexys4 (xc7a100tcsg324-1)
## Ports are matched to current top-level design:
##   clk, btnC, sw[3:0], led[3:0], RsTx

## Clock
set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports clk]

## Reset button (center)
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports btnC]

## Switches
set_property -dict { PACKAGE_PIN U9 IOSTANDARD LVCMOS33 } [get_ports {sw[0]}]
set_property -dict { PACKAGE_PIN U8 IOSTANDARD LVCMOS33 } [get_ports {sw[1]}]
set_property -dict { PACKAGE_PIN R7 IOSTANDARD LVCMOS33 } [get_ports {sw[2]}]
set_property -dict { PACKAGE_PIN R6 IOSTANDARD LVCMOS33 } [get_ports {sw[3]}]

## LEDs
set_property -dict { PACKAGE_PIN T8 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN V9 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN R8 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN T6 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]

## USB-UART (FPGA TX -> host RX)
set_property -dict { PACKAGE_PIN D4 IOSTANDARD LVCMOS33 } [get_ports RsTx]

## Configuration options
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]

## Ignore false paths between external board clock and generated cpu clock
set_false_path -from [get_clocks sys_clk_pin] -to [get_clocks -of_objects [get_pins soc_top_inst/clk_wiz_0/inst/mmcm_adv_inst/CLKOUT0]]
set_false_path -from [get_clocks -of_objects [get_pins soc_top_inst/clk_wiz_0/inst/mmcm_adv_inst/CLKOUT0]] -to [get_clocks sys_clk_pin]
