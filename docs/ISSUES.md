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
