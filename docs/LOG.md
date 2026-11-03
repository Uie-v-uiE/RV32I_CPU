# LOG — z7-rv32i-soc

## 2026-11-04
- 立项:避让已提交的视频比赛项目,选 CPU 方向补齐简历(与 FFT 的 DSP 路线互补)。
- golden/rv_iss.py:ISS + 两遍扫描迷你汇编器;5 测试程序(crc/fib/alu/mem/branch)
  全部停机正确,tohost 均写入。调试修:B 型立即数符号阈值、jal 双形式、
  寄存器别名、alu halting。
- rtl/rv32i_core.v:五级流水 + 前递 + load-use 停顿 + 两泡冲刷 + GPIO/tohost MMIO。
- 仿真:X 传播阻塞(I-01 OPEN),ISS 黄金模型独立有效,RTL 待修后接踪迹比对。
