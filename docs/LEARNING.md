# LEARNING — RV32I CPU: Architecture Deep Dive & Knowledge Guide

This document explains the pipeline architecture, the "why" behind each design decision, and the computer architecture knowledge needed to understand and extend this project.

---

## 1. RISC-V ISA Basics

### 1.1 RV32I Base Integer ISA

RV32I defines 47 instructions operating on 32 registers (x0–x31), where x0 is hardwired to zero. Key categories:

| Type | Instructions | Encoding fields |
|---|---|---|
| R-type | ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND | funct7, rs2, rs1, funct3, rd, opcode |
| I-type | ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI, JALR, LB, LH, LW, LBU, LHU | imm[11:0], rs1, funct3, rd, opcode |
| S-type | SB, SH, SW | imm[11:5], rs2, rs1, funct3, imm[4:0], opcode |
| B-type | BEQ, BNE, BLT, BGE, BLTU, BGEU | imm[12|10:5], rs2, rs1, funct3, imm[4:1|11], opcode |
| U-type | LUI, AUIPC | imm[31:12], rd, opcode |
| J-type | JAL | imm[20|10:1|11|19:12], rd, opcode |

### 1.2 Why start with RV32I?

- Simplest complete ISA — all instructions fit in one clock cycle
- No multiply/divide (those are M-extension), no floating point
- Well-documented spec (riscv-spec.pdf), extensive tooling
- Foundation for RV32M/RV32A/RV32F extensions

---

## 2. Pipeline Architecture

### 2.1 The 5-stage pipeline

```
IF → ID → EX → MEM → WB
```

| Stage | Function | Key components |
|---|---|---|
| IF | Fetch instruction from memory | PC register, memory read port |
| ID | Decode instruction, read registers | Register file (32×32), immediate generator, hazard detection |
| EX | Execute ALU, resolve branch, compute address | ALU, branch comparator, forwarding muxes |
| MEM | Data memory access | Data memory read/write port |
| WB | Write back result to register file | Write enable mux, write data mux |

### 2.2 Pipeline registers

Between each stage, a register holds the instruction's state:

```
IF/ID: pc, instruction
ID/EX: pc, rs1_data, rs2_data, rd, imm, alu_op, mem_read, mem_write, ...
EX/MEM: pc, alu_result, rs2_data, rd, mem_read, mem_write, ...
MEM/WB: pc, load_data, alu_result, rd, reg_write, ...
```

Each pipeline register is written on every clock edge (when not stalled/flushed).

### 2.3 Data hazards

A data hazard occurs when an instruction needs a value that hasn't been written back yet.

**Example:**
```
ADD x1, x2, x3    # x1 written in WB stage (cycle 5)
SUB x4, x1, x5    # x1 needed in EX stage (cycle 4) — HAZARD!
```

**Solution: Forwarding**
- EX/MEM pipeline register → EX stage input (for ALU results)
- MEM/WB pipeline register → EX stage input (for loaded data)
- The forwarding mux selects between: register file value, EX/MEM value, MEM/WB value

**Load-use hazard:**
```
LW  x1, 0(x2)     # x1 available at end of MEM (cycle 4)
ADD x3, x1, x4    # x1 needed at start of EX (cycle 4) — CANNOT forward!
```

The data is only available AFTER the memory access, so forwarding can't help. Solution: **stall 1 cycle** (insert a NOP), then use the MEM/WB forwarding path.

### 2.4 Control hazards

Branches are resolved in the EX stage, which means 2 instructions after the branch have already been fetched and decoded. When the branch is taken:
1. Flush IF/ID and ID/EX pipeline registers (insert NOPs)
2. Redirect PC to the branch target

This costs 2 cycles per taken branch. More advanced designs use branch prediction to reduce this penalty.

### 2.5 Forwarding implementation

The forwarding logic compares register numbers:
```
fwd_a = (dex_rs1 == exm_rd && exm_wr && !exm_ld) ? exm_alu :    # EX→EX forward
        (dex_rs1 == mwb_rd && mwb_wr) ? mwb_ldata : rf[dex_rs1]  # MEM→EX forward
```

Key subtlety: `!exm_ld` excludes load instructions from the EX→EX forwarding path (their data isn't ready yet — that's the load-use hazard).

### 2.6 Why EX-stage decode
