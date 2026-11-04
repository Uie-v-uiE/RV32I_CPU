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

## I-04/I-06 已收口:5/5 测试踪迹比对全 PASS(2026-11-05 第三轮)
从 fib 221 errors 修到 5/5 全 PASS(fib 204/crc 3892/alu 16/mem 16/branch 18 retires),
本轮共挖出 8 个真 bug,按发现顺序:
1. **sw/lw 地址 = slt(f3==2 分派)**:ALU 的 f3 case 对 load/store 也生效,sw f3=2
   走进 slt,地址恒 0(SWDBG 抓到 16 次 sw 全写 addr=0)。修:load/store 强制 sum。
2. **前递兜底窗口外**:距离 3 的依赖(如 addi a2 → 3 条后的 sw)落在 EX/MEM、MEM/WB
   两拍前递窗口之外,而 ID 采样值已旧。修:兜底前递改寄存器堆实时读 rf_lv1/rf_lv2。
3. **load-use 停顿吞指令**:stall 拍 IF/ID 仅保持 ifd_v,pc/inst 无条件重载——pc 已指
   下一条,IF 重读覆盖被停指令,依赖指令永久丢失(add a4 全被吞 → a4=0)。修:stall
   拍 ifd_pc/ifd_inst/ifd_v 整体保持。
4. **retire wdata 未屏蔽**:store/branch 的 retire wdata 暴露内部 ALU 值,与 ISS 约定
   (不写回 = 0)不一致。修:ret_wdata = mwb_wr ? rf_wd : 0。
5. **dmem 同步读与 mwb_ldata 同沿级联**:`dmem_rd <= mem[...]`(寄存读)与
   `mwb_ldata <= ld_data` 同一时钟沿,非阻塞赋值采到旧 dmem_rd → load 数据错位一拍
   (lw 拿到上一条访存地址的数据)。修:dmem 组合读(LUTRAM)。
6. **$signed >>> 被嵌套三元污染**:ModelSim 按 IEEE context-determined 规则,三元链
   混入 unsigned 分支后 $signed(op_a) 强转 unsigned,srai 走成 srli(最小复现实验:
   direct=fffff000 ✓,mux=0ffff000 ✗)。修:显式符号填充 sra_res = (a>>s) | (fill<<32-s)。
7. **子字访问三连**:lb/lh 符号扩展复制了整个字段(0x34 → 0x34343434)而非符号位;
   lh/lhu 半字偏移未按 lane[1] 取(越界读 X);sb/sh 无子字合并且 dmem[i][part]<=...
   在 Verilog-2001 非法(ModelSim 静默丢写)。修:符号位扩展 + lane 判位 + 整字读改写。
8. **哈佛 vs 冯诺依曼存储模型不一致**:头注释与 ISS 约定统一 8KB,RTL 却做成 prog/dmem
   分离——crc 的 lw a3,0(a0)(a0=0)读程序首字 0x37,dmem 读 0,数据流分叉,retire 数
   差 244(xori 执行次数不同)。修:统一存储 umem(2048×32)+ 全零初始化。

**ISS 侧同期修 3 处黄金模型 bug**(疑为真值前先审计):
a. I 型 ALU 查表 f3 错位:srai(f3=5)索引到 srli、andi(f3=7)索引到 ori;
b. slt/slti 用 Python int 直比(无符号存储值),负数比较错——sa/sb signed 视图;
c. blt/bge 同样无符号比较 bug(branch 测试正值数据未暴露)。

教训:踪迹比对首个失配点未必是根因(fib 首错 retire 119,真 bug 在 retire 0 的
sw 地址);SWDBG/LDBG/SRADBG 级探针 + 最小复现实验是定位关键。
