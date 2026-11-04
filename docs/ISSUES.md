# ISSUES — z7-rv32i-soc

## I-01 已修:PC/flush 的 X 泄漏(已提交)
reset 瞬态期 ifd_inst=X → redirect=X → pc/valid 链全 X。修复:pc 与 flush 均按 dex_v 过滤,
ifd_inst 复位值置 NOP(0x13)。

## I-02 已修:EX 段用错指令译码(已提交)
EX 的 is_jal/is_branch/is_store 等原用 IF/ID 级组合信号(=下一条指令!),重写为全部从
dex_inst(ID/EX 寄存后)译码。修复后流水线正确跑通 fib 全程序(pc 轨迹含循环与 jal)。

## I-03 MEM/WB 级寄存器未赋值(已修)
重写时漏掉 mwb_v/pc/alu/ldata 的整段赋值,导致 retired=0。已补。

## I-04 当前 OPEN:踪迹不匹配(前递细节)
- 现象:fib 340/612 字错。首错 retire5 = `add a4,a0,a1`:wdata got 0xb exp 0x1。
- retires 0-4(含 addi a0=0/a1=1/a2=256/a3=16 与 sw)全部正确。
- RFDBG 超时后镜像:rf[x] = 0x3bad0 + x(连续模式,非程序应有值),tohost 未置位
  (程序 400K 拍未到 halt,疑循环失控或访存地址走飞)。
- 下一步(新会话,~30 分钟):
  1. TB 打印 dut.dex_rsv1/rsv2 与 fwd_a/fwd_b 逐拍(retire 5 的 EX 前 3 拍)
  2. 对照 ISS 的 a0=0/a1=1,前递源应为 dex_rsv 旧值(无 fwd 需求)
  3. 重点检查 rf 异步读 + mwb 同步写的读旧值窗口,及 dex_rsv 采样时序
- ISS 侧完全可信(独立验证过),全部问题在 RTL 数据链。
