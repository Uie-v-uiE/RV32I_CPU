vlib sim/work
vmap work sim/work
vlog rtl/rv32i_core.v tb/tb_rv32i.v
vsim work.tb_rv32i +TRACE=vectors/trace.hex
run 200 ns
examine /tb_rv32i/ret_valid
examine -radix unsigned /tb_rv32i/dut/pc
examine -radix hex /tb_rv32i/dut/ifd_inst
examine /tb_rv32i/dut/ifd_v
examine /tb_rv32i/dut/dex_v
examine /tb_rv32i/dut/stall
examine /tb_rv32i/dut/flush
run 200 ns
examine -radix unsigned /tb_rv32i/dut/pc
examine /tb_rv32i/ret_valid
examine /tb_rv32i/dut/stall
quit -f
