#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成各测试的程序映像与 ISS 踪迹文件(prog.hex / trace.hex),供 ModelSim TB 使用。"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv_iss import TESTS, build_test

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "vectors")
os.makedirs(OUT, exist_ok=True)

name = sys.argv[1] if len(sys.argv) > 1 else "fib"
words, labels, iss = build_test(name)
with open(os.path.join(OUT, "prog.hex"), "w") as fp:
    for w in words:
        fp.write(("%08X" + chr(10)) % w)
with open(os.path.join(OUT, "trace.hex"), "w") as fp:
    for pc, inst, rdv, rd, wdata in iss.trace:
        fp.write(("%08X" + chr(10)) % pc)
        fp.write(("%08X" + chr(10)) % wdata)
        fp.write(("%08X" + chr(10)) % ((1 << 5) | rd if rdv else 0))
print("%-8s: %3d words, %4d retires, tohost=%s" % (name, len(words), len(iss.trace), iss.tohost))
