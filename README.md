# z7-rv32i-soc — RV32I 五级流水处理器(RK-ZYNQ7020-F)

自研 RV32I 基址整数子集 CPU,五级顺序流水(IF/ID/EX/MEM/WB),
双源前递 + load-use 停顿 + 分支两泡冲刷;统一 GPIO/tohost MMIO。
验证方法:Python ISS 逐条退休踪迹 (pc, rd_en, rd, wdata) 与 RTL WB 级 1:1 比对。

## 状态(2026-11-04)
- ✅ golden/rv_iss.py:ISS + 迷你汇编器,5 个测试程序全部通过
  (crc 4139 条、fib 204、alu 16、mem 16、branch 18 退休;tohost 均正确)
- ✅ rtl/rv32i_core.v:五级流水 RTL 完成
- ⚠️ ModelSim 仿真:X 传播导致 0 退休,定位到程序存储器初始化/加载路径,OPEN
  (见 docs/ISSUES.md I-01;ISS 黄金模型已独立验证,RTL 侧待修)

## 结构
    rtl/    rv32i_core.v(五级流水)
    golden/ rv_iss.py(ISS+汇编器+测试程序)
    tb/     tb_rv32i.v(踪迹比对)
    vectors/ 程序映像与踪迹(gen_prog.py 生成)
    sim/    ModelSim 脚本

## 复现
    cd golden && python gen_prog.py fib   # 生成 vectors/prog.hex + trace.hex
    vsim -c -do sim/rv.do
