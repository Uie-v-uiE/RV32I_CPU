# RV32I 7020 OOC 综合与时序报告
set part xc7z020clg484-2
set out results
create_project -force rv_synth build/rv_synth -part $part
add_files rtl/rv32i_core.v
add_files -fileset constrs_1 constr/rv32i.xdc
set_property top rv32i_core [current_fileset]
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
set synth_ok [expr {[get_property PROGRESS [get_runs synth_1]] == "100%"}]
if {!$synth_ok} { puts "SYNTH FAIL"; exit 1 }
open_run synth_1
report_timing_summary -file $out/rv_timing_ooc.rpt
report_utilization -file $out/rv_util_ooc.rpt
# BRAM 的 PROG 初始化在 OOC 无 readmemh,仅看时序/资源
puts "SYNTH DONE"
