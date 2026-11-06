# z7_rv32i_board.xdc — RK-ZYNQ7020-F 板级引脚(引脚事实同 z7-hdmi-display 已验证集)
set_property -dict {PACKAGE_PIN W17 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name sys_clk [get_ports clk]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports key1_n]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports led1]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
