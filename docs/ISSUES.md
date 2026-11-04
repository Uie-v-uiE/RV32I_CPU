# ISSUES — z7-rv32i-soc

## I-01 已修:PC/flush 的 X 泄漏(已提交)
reset 瞬态期 ifd_inst=X → redirect=X → pc/valid 链全 X。修复:pc 与 flush 均按 dex_v 过滤,
ifd_inst 复位值置 NOP(0x13)。

## I-02 已修:EX 段用错指令译码(已提交)
EX 的 is_jal/is_branch/is_store 等原用 IF/ID 级组合信号(=下一条指令!),重写为全部从
dex_inst(ID/EX 寄存后)译码。修复后流水线正确跑通 fib 全程序(pc 轨迹含循环与 jal)。

## I-03 MEM/WB 级寄存器未赋值(已修)
重写时漏掉 mwb_v/pc/alu/ldata 的整段赋值,导致 retired=0。已补。

## I-04 已修一半:前递条件自比错(已提交)
- 根因:fwd 条件用 dex_rs1 == dex_rd(EX 自身 rd 自比)——凡 rs1==自身rd 的指令
  (如 addi a2,a2,4)把上一条指令的 alu 结果错误前递。修为 dex_rs1 == exm_rd。
- 修后:fib 数据通路第一遍全对(retires 0-118 逐位一致,含全部 add/addi/sw)。

## I-06 当前 OPEN:多指针场景 rf 污染
- 现象:fib 340/612 字错。首错 retire5 = `add a4,a0,a1`:wdata got 0xb exp 0x1。
- retires 0-4(含 addi a0=0/a1=1/a2=256/a3=16 与 sw)全部正确。
- RFDBG 超时后镜像:rf[x] = 0x3bad0 + x(连续模式,非程序应有值),tohost 未置位
  (程序 400K 拍未到 halt,疑循环失控或访存地址走飞)。
- 本轮新证据(RFHIST):唯一一条 WB 写 pc=0x20(addi a2,a2,4)wd=0x3badf
  = a1 的值(0x3badb)+4,即 rs1=x12 的操作数被送入了 a1(x11)的值——
  前递/读口在 x11/x12 之间串了;且 rf 全体呈现 rf[x]=0x3bad0+x 的模式。
- 新证据:RFHIST 唯一 WB 写 pc=0x20 wd=0x3badf = a1_val+4(修前);修后 fib 第一遍全对。
- 现象:第二遍起 rf[x] = 0x3bad0+x(a2 指针 40 万拍走飞后),tohost 未达。
- 下一步(新会话,~30 分钟):
  1. TB 打印 dut.dex_rsv1/rsv2 与 fwd_a/fwd_b 逐拍(retire 5 的 EX 前 3 拍)
  2. 对照 ISS 的 a0=0/a1=1,前递源应为 dex_rsv 旧值(无 fwd 需求)
  3. 重点检查 rf 异步读 + mwb 同步写的读旧值窗口,及 dex_rsv 采样时序
- ISS 侧完全可信(独立验证过),全部问题在 RTL 数据链。

## I-05 本轮修复(2026-11-04 第二轮,已提交)
1. pc 的 X 泄漏:redirect 未按 dex_v 过滤(复位瞬态 X 经组合链污染 PC)
2. flush 同样泄漏
3. EX 段控制信号(is_jal/is_branch/is_store/is_lui 等)误用 IF/ID 级组合译码
   (= 下一条指令!),重写为全部从 dex_inst(ID/EX 寄存后)译码
4. MEM/WB 级寄存器整段漏赋值(mwb_v/pc/alu/ldata 从未更新 → retired=0)
修复后:流水线跑通 fib 全程序(pc 轨迹含 16 次循环与 jal 回跳),5 测试全部
执行至 tohost/超时,退休计数正确量级。
