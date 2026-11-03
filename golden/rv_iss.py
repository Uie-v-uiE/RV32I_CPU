#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RV32I(+Zicsr 子集)指令集模拟器 + 迷你汇编器 + 测试程序生成 —— 黄金模型。

用途:
  1. 生成测试程序映像(asm → hex,供 BRAM INIT 与 ModelSim $readmemh);
  2. 逐条退休指令踪迹 (pc, inst, rd_valid, rd, wdata) —— 与 RTL WB 级踪迹 1:1 比对;
  3. 末端寄存器堆/存储器镜像比对。

约定(与 RTL 一致):
  - 指令/数据统一 8KB BRAM(字编址接口,按字节寻址 0x0000_0000 起);
  - MMIO: 0x0000_1000 = GPIO 输出(写); 0x0000_1008 = tohost(写即测试结束);
  - x0 恒 0;无 CSR(本子集不实现,避免范围蔓延);ecall/nop 处理为普通指令。
"""
import re, random

MEM_WORDS = 2048            # 8KB
GPIO_ADDR = 0x1000
TOHOST_ADDR = 0x1008

# ---------------------------------------------------------------- 汇编器
REG = {f"x{i}": i for i in range(32)}
for i, n in enumerate("zero ra sp gp tp t0 t1 t2 s0 s1".split()):
    REG[n] = i
for i in range(8):
    REG["a%d" % i] = 10 + i
for i in range(10):
    REG["s%d" % (i + 2)] = 18 + i
for i in range(4):
    REG["t%d" % (i + 3)] = 28 + i

def reg(tok):
    tok = tok.strip()
    assert tok in REG, f"bad reg {tok}"
    return REG[tok]

def imm(tok):
    tok = tok.strip()
    return int(tok, 0)

def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def enc_i(imm12, rs1, f3, rd, op):
    return ((imm12 & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def enc_s(imm12, rs2, rs1, f3, op):
    return (((imm12 >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm12 & 0x1F) << 7) | op

def enc_b(imm13, rs2, rs1, f3, op):
    return (((imm13 >> 12) & 1) << 31) | (((imm13 >> 5) & 0x3F) << 25) | (rs2 << 20) | \
           (rs1 << 15) | (f3 << 12) | (((imm13 >> 1) & 0xF) << 8) | (((imm13 >> 11) & 1) << 7) | op

def enc_u(imm20, rd, op):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | op

def enc_j(imm21, rd, op):
    return (((imm21 >> 20) & 1) << 31) | (((imm21 >> 1) & 0x3FF) << 21) | \
           (((imm21 >> 11) & 1) << 20) | (((imm21 >> 12) & 0xFF) << 12) | (rd << 7) | op

def assemble(src):
    """两遍扫描:标签 + 指令。返回 (words:list[int], labels:dict)"""
    lines = []
    for raw in src.split("\n"):
        line = raw.split("#")[0].strip()
        if line:
            lines.append(line)
    labels = {}
    addr = 0
    for ln in lines:
        m = re.match(r"^([A-Za-z_][\w]*):", ln)
        if m:
            labels[m.group(1)] = addr
            ln = ln[m.end():].strip()
        if ln:
            addr += 4
    words = []
    addr = 0
    for ln in lines:
        m = re.match(r"^([A-Za-z_][\w]*):", ln)
        if m:
            ln = ln[m.end():].strip()
        if not ln:
            continue
        parts = ln.replace(",", " ").split()
        op, args = parts[0].lower(), parts[1:]
        pc = addr
        if op == "nop":
            w = enc_i(0, 0, 0, 0, 0x13)
        elif op in ("add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"):
            f3 = dict(add=0, sub=0, sll=1, slt=2, sltu=3, xor=4, srl=5, sra=5, or_=6, and_=7)[op]
            f7 = 0x20 if op in ("sub", "sra") else 0
            w = enc_r(f7, reg(args[2]), reg(args[1]), f3, reg(args[0]), 0x33)
        elif op in ("addi", "slti", "sltiu", "xori", "ori", "andi"):
            f3 = dict(addi=0, slti=2, sltiu=3, xori=4, ori=6, andi=7)[op]
            w = enc_i(imm(args[2]), reg(args[1]), f3, reg(args[0]), 0x13)
        elif op in ("slli", "srli", "srai"):
            f3 = dict(slli=1, srli=5, srai=5)[op]
            f7 = 0x20 if op == "srai" else 0
            w = enc_r(f7, imm(args[2]) & 0x1F, reg(args[1]), f3, reg(args[0]), 0x13)
        elif op in ("lb", "lh", "lw", "lbu", "lhu"):
            f3 = dict(lb=0, lh=1, lw=2, lbu=4, lhu=5)[op]
            m2 = re.match(r"(-?[\w]+)\((\w+)\)", args[1])
            w = enc_i(imm(m2.group(1)), reg(m2.group(2)), f3, reg(args[0]), 0x03)
        elif op in ("sb", "sh", "sw"):
            f3 = dict(sb=0, sh=1, sw=2)[op]
            m2 = re.match(r"(-?[\w]+)\((\w+)\)", args[1])
            w = enc_s(imm(m2.group(1)), reg(args[0]), reg(m2.group(2)), f3, 0x23)
        elif op in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            f3 = dict(beq=0, bne=1, blt=4, bge=5, bltu=6, bgeu=7)[op]
            off = labels[args[2]] - pc
            assert off % 4 == 0 and -4096 <= off < 4096
            w = enc_b(off, reg(args[1]), reg(args[0]), f3, 0x63)
        elif op == "jal":
            if len(args) == 1:                     # jal label(rd=ra)
                off = labels[args[0]] - pc
                w = enc_j(off, 1, 0x6F)
            else:
                tgt = args[1].strip()
                off = labels[tgt] - pc if tgt in labels else imm(tgt)
                w = enc_j(off, reg(args[0]), 0x6F)
        elif op == "jalr":
            m2 = re.match(r"(-?[\w]+)\((\w+)\)", args[1])
            w = enc_i(imm(m2.group(1)), reg(m2.group(2)), 0, reg(args[0]), 0x67)
        elif op == "lui":
            w = enc_u(imm(args[1]), reg(args[0]), 0x37)
        elif op == "auipc":
            w = enc_u(imm(args[1]), reg(args[0]), 0x17)
        elif op == "ecall":
            w = 0x73
        else:
            raise ValueError(f"bad op {op}")
        words.append(w)
        addr += 4
    return words, labels

# ---------------------------------------------------------------- ISS
class ISS:
    def __init__(self, words):
        self.mem = [0] * MEM_WORDS
        for i, w in enumerate(words):
            self.mem[i] = w & 0xFFFFFFFF
        self.x = [0] * 32
        self.pc = 0
        self.trace = []          # (pc, inst, rd_valid, rd, wdata)
        self.gpio = 0
        self.tohost = None
        self.cycles = 0

    def lb(self, a):
        b = (self.mem[(a >> 2) & (MEM_WORDS-1)] >> ((a & 3) * 8)) & 0xFF
        return b - 256 if b >= 128 else b
    def lh(self, a):
        h = (self.mem[(a >> 2) & (MEM_WORDS-1)] >> ((a & 2) * 8)) & 0xFFFF
        return h - 65536 if h >= 32768 else h
    def lw(self, a):
        return self.mem[(a >> 2) & (MEM_WORDS-1)]
    def sb(self, a, v):
        w = self.mem[(a >> 2) & (MEM_WORDS-1)]
        sh = (a & 3) * 8
        self.mem[(a >> 2) & (MEM_WORDS-1)] = (w & ~(0xFF << sh) | ((v & 0xFF) << sh)) & 0xFFFFFFFF
    def sh(self, a, v):
        w = self.mem[(a >> 2) & (MEM_WORDS-1)]
        sh = (a & 2) * 8
        self.mem[(a >> 2) & (MEM_WORDS-1)] = (w & ~(0xFFFF << sh) | ((v & 0xFFFF) << sh)) & 0xFFFFFFFF
    def sw(self, a, v):
        self.mem[(a >> 2) & (MEM_WORDS-1)] = v & 0xFFFFFFFF

    def step(self):
        if self.tohost is not None:
            return False
        pc = self.pc
        inst = self.lw(pc)
        op = inst & 0x7F
        rd = (inst >> 7) & 0x1F
        f3 = (inst >> 12) & 7
        rs1 = (inst >> 15) & 0x1F
        rs2 = (inst >> 20) & 0x1F
        f7 = (inst >> 25) & 0x7F
        a = self.x[rs1]
        b = self.x[rs2]
        iimm = inst >> 20
        iimm = iimm - 4096 if iimm >= 2048 else iimm
        simm = ((inst >> 25) << 5) | ((inst >> 7) & 0x1F)
        simm = simm - 4096 if simm >= 2048 else simm
        bimm = ((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) | (((inst >> 25) & 0x3F) << 5) | (((inst >> 8) & 0xF) << 1)
        bimm = bimm - 8192 if bimm >= 4096 else bimm   # 13 位 B 型立即数,阈值 2^12
        uimm = inst & 0xFFFFF000
        jimm = ((inst >> 31) << 20) | (((inst >> 12) & 0xFF) << 12) | (((inst >> 20) & 1) << 11) | (((inst >> 21) & 0x3FF) << 1)
        jimm = jimm - (1 << 21) if jimm >= (1 << 20) else jimm
        rdv, nxt = None, pc + 4
        if op == 0x33:
            if f7 == 0x00:
                rdv = [ (a + b) & 0xFFFFFFFF, (a << (b & 31)) & 0xFFFFFFFF,
                        (1 if a < b else 0), (1 if (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF) else 0),
                        a ^ b, (a & 0xFFFFFFFF) >> (b & 31),
                        ((a - (1 << 32) if a & (1 << 31) else a) >> (b & 31)) & 0xFFFFFFFF,
                        a | b, a & b ][f3]
            elif f7 == 0x20 and f3 == 0:
                rdv = (a - b) & 0xFFFFFFFF
            elif f7 == 0x20 and f3 == 5:
                sa = a - (1 << 32) if a & (1 << 31) else a
                rdv = (sa >> (b & 31)) & 0xFFFFFFFF
        elif op == 0x13:
            rdv = [ (a + iimm) & 0xFFFFFFFF, None, (1 if a < iimm else 0),
                    (1 if (a & 0xFFFFFFFF) < (iimm & 0xFFFFFFFF) else 0), a ^ iimm,
                    (a & 0xFFFFFFFF) >> (iimm & 31),
                    ((a - (1<<32) if a & (1<<31) else a) >> (iimm & 31)) & 0xFFFFFFFF,
                    a | iimm, a & iimm ][f3]
            if f3 == 1:
                rdv = (a << (iimm & 31)) & 0xFFFFFFFF
        elif op == 0x03:
            rdv = dict([(0, lambda: self.lb(a + iimm) & 0xFFFFFFFF), (1, lambda: self.lh(a + iimm) & 0xFFFFFFFF),
                        (2, lambda: self.lw(a + iimm) & 0xFFFFFFFF),
                        (4, lambda: self.lb(a + iimm)), (5, lambda: self.lh(a + iimm))])[f3]()
        elif op == 0x23:
            ea = (a + simm) & 0xFFFFFFFF
            if ea == GPIO_ADDR:
                self.gpio = b & 0xFFFFFFFF
            elif ea == TOHOST_ADDR:
                self.tohost = b & 0xFFFFFFFF
            else:
                [self.sb, self.sh, self.sw][f3](ea, b)
        elif op == 0x63:
            take = dict([(0, lambda: a == b), (1, lambda: a != b), (4, lambda: a < b),
                         (5, lambda: a >= b), (6, lambda: (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF)),
                         (7, lambda: (a & 0xFFFFFFFF) >= (b & 0xFFFFFFFF))])[f3]()
            nxt = pc + (bimm if take else 4)
        elif op == 0x6F:
            rdv = pc + 4
            nxt = pc + jimm
        elif op == 0x67:
            rdv = pc + 4
            nxt = (a + iimm) & 0xFFFFFFFE
        elif op == 0x37:
            rdv = uimm
        elif op == 0x17:
            rdv = (pc + uimm) & 0xFFFFFFFF
        elif op == 0x73:
            self.tohost = 0xDEAD
            return True
        if rdv is not None and rd != 0:
            self.x[rd] = rdv & 0xFFFFFFFF
        self.trace.append((pc, inst, rdv is not None, rd, (rdv or 0) & 0xFFFFFFFF))
        self.pc = nxt
        self.cycles += 1
        return True

def run_iss(words, max_cycles=200000):
    iss = ISS(words)
    while iss.step():
        if iss.cycles > max_cycles:
            raise RuntimeError("ISS timeout")
    return iss

# ---------------------------------------------------------------- 测试程序
def prog_crc():
    return """
# CRC32(逐位)计算 16 字表格并存回,结果写 GPIO —— 练习 lw/sw/xor/分支
        lui   a0, 0x0            # a0 = 0 数据基址
        addi  a1, a0, 0x100      # a1 = 表基址(数据区)
        addi  a2, zero, 16       # 计数
        lui   t0, 0x1            # t0 = 0x1000 逐位计数初值
crc_outer:
        lw    a3, 0(a0)
        addi  a0, a0, 4
        lui   t1, 0x1            # 位计数 = 0x800(实际用移位实现)
        addi  t1, zero, 32
crc_inner:
        addi  t1, t1, -1
        beq   t1, zero, crc_done
        andi  t2, a3, 1
        srli  a3, a3, 1
        beq   t2, zero, crc_shift
        xori  a3, a3, 0x400
crc_shift:
        beq   t1, zero, crc_inner
        jal   zero, crc_inner
crc_done:
        sw    a3, 0(a1)
        addi  a1, a1, 4
        addi  a2, a2, -1
        bne   a2, zero, crc_outer
        lw    a5, 0(a1)
        lui   t2, 0x1
        sw    a5, 0(t2)          # GPIO
        lui   t3, 0x1
        addi  t3, t3, 8
        addi  a5, zero, 1
        sw    a5, 0(t3)          # tohost
        jal   zero, crc_done
"""

def prog_fib():
    return """
# 斐波那契 16 项写入内存并求和
        addi  a0, zero, 0
        addi  a1, zero, 1
        addi  a2, zero, 0x100
        addi  a3, zero, 16
fib_lp:
        sw    a0, 0(a2)
        add   a4, a0, a1
        addi  a0, a1, 0
        addi  a1, a4, 0
        addi  a2, a2, 4
        addi  a3, a3, -1
        bne   a3, zero, fib_lp
        addi  a2, zero, 0x100
        addi  a3, zero, 16
        addi  a4, zero, 0
fib_sum:
        lw    a5, 0(a2)
        add   a4, a4, a5
        addi  a2, a2, 4
        addi  a3, a3, -1
        bne   a3, zero, fib_sum
        lui   t2, 0x1
        sw    a4, 0(t2)
        addi  t3, t2, 8
        addi  a5, zero, 2
        sw    a5, 0(t3)
        jal   zero, fib_sum
"""

def prog_alu():
    return """
# ALU 全指令边角:立即数符号/移位/比较
        addi  t0, zero, -1
        slli  t1, t0, 16
        srli  t2, t1, 4
        srai  t3, t1, 4
        slt   t4, t3, t2
        sltu  t5, t3, t2
        xori  t6, t3, 0x7FF
        ori   s0, t6, 0x400
        andi  s1, s0, 0xF0F
        sub   s2, t2, t3
        lui   s3, 0xDEAD0
        addi  s3, s3, -493
        lui   t2, 0x1
        sw    s1, 0(t2)
        sw    s2, 4(t2)
        sw    s3, 8(t2)
        addi  t3, t2, 8
        addi  a5, zero, 3
        sw    a5, 0(t3)
        addi  t3, t2, 12
        addi  a5, zero, 1
        sw    a5, 0(t3)              # tohost
        addi  t4, t2, 20
        addi  a5, zero, 3
        sw    a5, 0(t4)
        jal   zero, 0
"""

def prog_mem():
    return """
# 存储器子字读写:lb/lbu/lh/lhu/sb/sh 符号扩展验证
        lui   t0, 0x1
        addi  t0, t0, -0x800      # t0 = 0x800(数据区)
        lui   t1, 0x12346
        addi  t1, t1, -0x78A      # t1 = 0x12345776
        sw    t1, 0(t0)
        lb    a0, 2(t0)
        lbu   a1, 2(t0)
        lh    a2, 2(t0)
        lhu   a3, 0(t0)
        sb    a0, 5(t0)
        sh    a2, 6(t0)
        lw    a4, 4(t0)
        lui   t2, 0x1
        sw    a0, 0(t2)
        sw    a1, 4(t2)
        sw    a2, 8(t2)
        sw    a3, 12(t2)
        sw    a4, 16(t2)
        addi  t3, t2, 16
        addi  a5, zero, 4
        sw    a5, 0(t3)
        jal   zero, -4
"""

def prog_branch():
    return """
# 分支/jal/jalr 全向:顺序、前跳、后跳、链接寄存器
        addi  s0, zero, 0
        addi  s1, zero, 4
        beq   s0, zero, L1
        addi  s0, s0, 100
L1:     bne   s0, s1, L2
        addi  s0, s0, 1000
L2:     blt   s0, s1, L3
        bge   s1, s0, L3
        addi  s0, s0, 10000
L3:     jal   ra, L4
        addi  s0, s0, 100000
L4:     auipc a2, 0
        addi  a3, a2, 24
        jalr  a4, 0(a3)
        addi  s0, s0, 1000000
L5:     lui   t2, 0x1
        sw    s0, 0(t2)
        addi  t3, t2, 8
        addi  a5, zero, 5
        sw    a5, 0(t3)
        jal   zero, L5
"""

TESTS = dict(crc=prog_crc, fib=prog_fib, alu=prog_alu, mem=prog_mem, branch=prog_branch)

def build_test(name):
    words, labels = assemble(TESTS[name]())
    iss = run_iss(words)
    return words, labels, iss

if __name__ == "__main__":
    for name in TESTS:
        words, labels, iss = build_test(name)
        wv = [(pc, rdv if rdv else 0) for pc, inst, rdv, rd, wv in iss.trace]
        print("%-8s: %3d instr words, retired %4d, tohost=%s gpio=%s" %
              (name, len(words), len(iss.trace), iss.tohost, iss.gpio))
