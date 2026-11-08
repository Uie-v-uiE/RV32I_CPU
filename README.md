# FPGA RV32I CPU

5-stage pipelined RV32I CPU on Zynq-7020 (RK-ZYNQ7020-F), verified against an instruction-set simulator (ISS) via retirement trace comparison.

[![Verification](https://img.shields.io/badge/verification-5%2F5%20tests%20PASS-brightgreen)]() [![Timing](https://img.shields.io/badge/timing-50MHz%20closed-blue)]() [![Board](https://img.shields.io/badge/board-7020%20verified-orange)]()

## What this does

A complete RV32I base integer ISA CPU with:
- 5-stage pipeline: IF → ID → EX → MEM → WB
- Full data hazard handling: dual-source forwarding + load-use stall
- Branch resolution in EX with 2-cycle flush penalty
- MMIO: GPIO (0x1000) and tohost (0x1008) for testing
- Harvard data memory: 1KB on-chip BRAM
- Board demo: fib program runs from BRAM, completion signaled via LED

## Verification

- **ISS co-simulation**: A Python-based instruction set simulator generates golden retirement traces (PC, RD, WDATA for every instruction). The RTL trace is compared cycle-by-cycle.
- **5 test programs**: ALU ops, branch/jump, load/store (byte/half/word), CRC computation, Fibonacci — all 5/5 PASS
- **Bug coverage**: 8 RTL bugs and 3 ISS bugs found and fixed during development

## Project structure

```
rtl/
  rv32i_core.v       — 5-stage pipeline CPU (forwarding, stall, flush, MMIO)
  z7_rv32i_board.v   — Board-level demo (fib in BRAM, tohost → LED)
golden/
  rv_iss.py          — Instruction set simulator (retirement trace generator)
  gen_prog.py        — Test program assembler/generator
vectors/
  prog_fib.hex       — Fibonacci program (25 instructions)
  prog_crc.hex       — CRC computation
  prog_alu.hex       — ALU operation sweep
  prog_mem.hex       — Memory operation sweep
  prog_branch.hex    — Branch/jump sweep
constr/
  z7_rv32i_board.xdc — Board pin constraints (50 MHz, LED, KEY)
scripts/
  synth_rv.tcl       — OOC synthesis
  build_board.tcl    — Board bitstream build
docs/
  DESIGN.md          — Pipeline architecture
  LOG.md             — Debugging chronology
  ISSUES.md          — Bug tracking
```

## Reproduce

```bash
# ModelSim simulation (trace comparison)
cd sim
vsim -c -do do rv_fib.do

# Vivado synthesis
vivado -mode batch -source scripts/synth_rv.tcl

# Board bitstream (7020)
vivado -mode batch -source scripts/build_board.tcl
```

## Board demo

Burn `z7_rv32i_board.bit` via JTAG. The CPU boots from BRAM containing a Fibonacci program. On completion, the `tohost` MMIO register is set, which lights LED0. LED1 blinks as a clock activity indicator.

## Pipeline architecture

```
     ┌────┐   ┌────┐   ┌────┐   ┌────┐   ┌────┐
────→│ IF │──→│ ID │──→│ EX │──→│MEM │──→│ WB │──→
     └──┬─┘   └──┬─┘   └──┬─┘   └──┬─┘   └──┬─┘
        │        │        │        │        │
        │   ┌────┘   ┌────┘        │        │
        │   │        │   ┌─────────┘        │
        │   │  RegFile(rf) │   Data Memory   │
        │   │  32×32-bit   │   1KB BRAM      │
        └───┴──────────────┴─────────────────┘

Forwarding paths:
  EX/MEM → EX (ALU result)
  MEM/WB → EX (load data + ALU result)

Hazards:
  Load-use: 1-cycle stall (if ID source == MEM dest)
  Branch:   2-cycle flush (resolved in EX)
```

## Key design decisions

1. **EX-stage decode**: All control signals are decoded from the instruction in the EX/ID pipeline register (`dex_inst`), not from the IF/ID stage. This avoids bugs when the instruction in EX differs from the one in ID during stalls.

2. **X-propagation guards**: `redirect` and `flush` are gated by `dex_v` (EX valid) to prevent X values from leaking into the PC during pipeline flush.

3. **Load-use stall**: When a load instruction is in MEM and the next instruction in EX needs the loaded value, a single-cycle stall is inserted. The forwarding path from MEM/WB handles the subsequent cycle.

4. **Real-time register file read**: The ID stage reads the register file combinationally (LUTRAM), so the value is always current — no need for a separate bypass path for ID-stage forwarding.
