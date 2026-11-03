vlib sim/work
vmap work sim/work
vlog rtl/rv32i_core.v tb/tb_rv32i.v
vsim work.tb_rv32i +TRACE=vectors/trace.hex
run -all
quit -f
