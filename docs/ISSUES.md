# ISSUES — z7-rv32i-soc

## I-01 RTL 仿真 0 退休(X 传播)(OPEN)
- 现象:ret_valid 全程 0;DBG 显示 pc/ifd_inst 早期为 X,prog[1] 已加载而 prog[0] 为 X。
- 已排除:$readmemh 路径(文件存在、警告消失)、参数覆盖(改硬编码)。
- 疑点:$readmemh 参数化(PROG 经 -g 传入)在 vsim 中的加载时序,或 initial 块与
  $readmemh 的顺序;建议改为 generate 内常量文件名或 $readmemh 后强制赋值验证。
- 影响:RTL 未上踪迹比对;ISS 黄金模型独立有效。
## I-02 已修
- B 型立即数符号扩展阈值 4096(12 位)→ 8192(13 位);jal 双形式;寄存器别名展开;
  alu 测试 halting 约定。均为 ISS/汇编器侧,由逐测试运行捕获。

## I-03 jal 目标计算错误(OPEN,已精确定位)
- 现象:fib 的 `jal zero, fib_sum`(@0x60,目标应为 0x40)实际跳到 0xe286a。
- 已验证:取指/译码正确(取到 0xfd9ff06f ✓);PC 泄漏已修(pc/flush 按 dex_v 过滤);
  EX 译码已改为全部使用 dex_inst(ID/EX 寄存后)。
- 疑点:imm_j 解码拼接或 target 三路选择;需波形对照 imm_j 逐位。
## I-04 数据链致 rf 污染(OPEN,与 I-03 可能同源)
- 现象:超时后 rf[x] = 0x3bad0+x(a0/a1 连续差 1,符合"错误加法下的 fib 对");
  fib 第一相前 5 条退休正确,分歧出现在循环/访存后的数据链。
- 波形建议:抓前 64 拍的 dex_rsv1/rsv2、fwd_a/fwd_b、rf_we 对拍 ISS。
