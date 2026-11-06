# RV32I 板级演示一键构建:synth + opt + place + route + bit(7020,50 MHz)
set part xc7z020clg484-2
set out results
file mkdir $out
create_project -force rv_board build/rv_board -part $part
add_files rtl/rv32i_core.v
add_files rtl/z7_rv32i_board.v
add_files vectors/prog_fib.hex
set_property file_type {Memory File} [get_files vectors/prog_fib.hex]
add_files -fileset constrs_1 constr/z7_rv32i_board.xdc
set_property top z7_rv32i_board [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { puts "SYNTH FAIL"; exit 1 }
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
set bit [glob -nocomplain build/rv_board/rv_board.runs/impl_1/*.bit]
if {[llength $bit] == 0} { puts "IMPL FAIL"; exit 1 }
open_run impl_1
report_timing_summary -file $out/rv_board_timing.rpt
puts "RV-BOARD BIT: [lindex $bit 0]"
puts "RV-BOARD DONE"
