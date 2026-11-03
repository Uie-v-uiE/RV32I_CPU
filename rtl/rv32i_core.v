// rv32i_core.v — RV32I 五级顺序流水核(教科书结构)。
//
//   IF  : 取指(程序 BRAM,2048×32,$readmemh 预置)
//   ID  : 译码 + 寄存器堆读(32×32 LUTRAM,x0 恒 0)+ load-use 检测
//   EX  : ALU / 分支比较 / 跳转 / 前递选择
//   MEM : 数据 BRAM(1024×32,哈佛结构)+ GPIO(0x1000)/tohost(0x1008)
//   WB  : 寄存器堆写回
//
// 冒险:双源前递(EX/MEM 非取值、MEM/WB 全部)+ load-use 一拍停顿;
//       分支/jal/jalr 在 EX 解析,冲刷 IF/ID、ID/EX(两泡)。
// 验证:golden/rv_iss.py ISS 逐条退休踪迹 (pc, rd_en, rd, wdata) 与 WB 级 1:1 比对。
// 哈佛结构:数据访问仅限数据区(dmem),测试程序数据基址 ≥ 0x100。

module rv32i_core #(
    parameter PROG = "prog.hex"
)(
    input  wire        clk,
    input  wire        rst,          // 同步复位,仅控制状态
    output wire [31:0] gpio_out,
    output wire        tohost,
    output wire [31:0] tohost_val,
    output wire        ret_valid,    // 退休踪迹(WB 级)
    output wire [31:0] ret_pc,
    output wire [4:0]  ret_rd,
    output wire        ret_rd_en,
    output wire [31:0] ret_wdata
);
    // ==================== 存储器 ====================
    (* ram_style = "block" *)
    reg [31:0] prog [0:2047];
    initial $readmemh(PROG, prog);

    (* ram_style = "block" *)
    reg [31:0] dmem [0:1023];
    integer zi;
    initial for (zi = 0; zi < 1024; zi = zi + 1) dmem[zi] = 32'b0;

    // ==================== 寄存器堆(异步读、同步写,x0 恒 0) ====================
    (* ram_style = "distributed" *)
    reg [31:0] rf [1:31];
    integer zi2;
    initial for (zi2 = 1; zi2 < 32; zi2 = zi2 + 1) rf[zi2] = 32'b0;

    // ==================== IF ====================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] imem_rdata = prog[pc[12:2]];

    // ==================== IF/ID ====================
    reg         ifd_v;
    reg [31:0]  ifd_pc, ifd_inst;

    // ==================== ID:译码 ====================
    wire [6:0]  opcode = ifd_inst[6:0];
    wire [4:0]  id_rd  = ifd_inst[11:7];
    wire [4:0]  id_rs1 = ifd_inst[19:15];
    wire [4:0]  id_rs2 = ifd_inst[24:20];
    wire [2:0]  id_f3  = ifd_inst[14:12];
    wire        is_load  = (opcode == 7'b0000011);
    wire        is_store = (opcode == 7'b0100011);
    wire        is_branch= (opcode == 7'b1100011);
    wire        is_jal   = (opcode == 7'b1101111);
    wire        is_jalr  = (opcode == 7'b1100111);
    wire        is_lui   = (opcode == 7'b0110111);
    wire        is_auipc = (opcode == 7'b0010111);
    wire        is_alui  = (opcode == 7'b0010011);
    wire        is_alur  = (opcode == 7'b0110011);
    wire        id_rd_wr = is_load || is_jal || is_jalr || is_lui || is_auipc || is_alui || is_alur;
    wire        id_us1   = !is_lui && !is_jal && !is_auipc;
    wire        id_us2   = is_alur || is_branch || is_store;

    wire [31:0] rv1 = (id_rs1 == 5'd0) ? 32'b0 : rf[id_rs1];
    wire [31:0] rv2 = (id_rs2 == 5'd0) ? 32'b0 : rf[id_rs2];

    // ==================== ID/EX ====================
    reg         dex_v;
    reg [31:0]  dex_pc, dex_inst, dex_rsv1, dex_rsv2;
    reg [4:0]   dex_rd, dex_rs1, dex_rs2;
    reg         dex_wr, dex_ld, dex_st, dex_br;
    reg [2:0]   dex_f3;
    // ==================== EX/MEM ====================
    reg         exm_v, exm_wr, exm_ld, exm_st;
    reg [31:0]  exm_pc, exm_alu, exm_stv;
    reg [4:0]   exm_rd;
    reg [2:0]   exm_f3;

    // ==================== MEM/WB ====================
    reg         mwb_v, mwb_wr, mwb_ld;
    reg [31:0]  mwb_pc, mwb_alu, mwb_ldata;
    reg [4:0]   mwb_rd;

    // ==================== 前递(EX 输入) ====================
    wire        exm_fwd_v = exm_v && exm_wr && !exm_ld;   // 取值尚未就绪的 load 不前递
    wire [31:0] fwd_a = (dex_v && dex_rs1 != 0 && dex_rs1 == dex_rd && exm_fwd_v) ? exm_alu :
                        (dex_v && dex_rs1 != 0 && dex_rs1 == mwb_rd && mwb_v && mwb_wr) ? (mwb_ld ? mwb_ldata : mwb_alu) :
                        dex_rsv1;
    wire [31:0] fwd_b = (dex_v && dex_rs2 != 0 && dex_rs2 == dex_rd && exm_fwd_v) ? exm_alu :
                        (dex_v && dex_rs2 != 0 && dex_rs2 == mwb_rd && mwb_v && mwb_wr) ? (mwb_ld ? mwb_ldata : mwb_alu) :
                        dex_rsv2;

    // ==================== EX ====================
    wire [31:0] imm_i = {{20{dex_inst[31]}}, dex_inst[31:20]};
    wire [31:0] imm_s = {{20{dex_inst[31]}}, dex_inst[31:25], dex_inst[11:7]};
    wire [31:0] imm_b = {{19{dex_inst[31]}}, dex_inst[31], dex_inst[7], dex_inst[30:25], dex_inst[11:8], 1'b0};
    wire [31:0] imm_u = {dex_inst[31:12], 12'b0};
    wire [31:0] imm_j = {{11{dex_inst[31]}}, dex_inst[31], dex_inst[19:12], dex_inst[20], dex_inst[30:21], 1'b0};

    wire        sub_sel  = dex_inst[30] & (is_alur | (is_alui & (dex_f3 == 3'd5)));
    wire [31:0] op_a     = is_auipc ? dex_pc : fwd_a;                       // auipc 用 pc
    wire [31:0] op_b     = (is_lui | is_auipc) ? imm_u :
                           (is_jal)            ? imm_j :
                           (is_branch)         ? imm_b :
                           (is_store)          ? imm_s : imm_i;
    wire [4:0]  shamt    = op_b[4:0];
    wire [31:0] sum      = op_a + op_b;
    wire [31:0] alu_out =
        is_branch ? 32'b0 :
        is_jal    ? dex_pc + 32'd4 :
        is_jalr   ? dex_pc + 32'd4 :
        is_lui    ? imm_u :
        is_auipc  ? sum :
        (dex_f3 == 3'd0) ? (sub_sel ? (op_a - op_b) : sum) :
        (dex_f3 == 3'd1) ? (op_a << shamt) :
        (dex_f3 == 3'd2) ? {31'b0, $signed(op_a) < $signed(op_b)} :
        (dex_f3 == 3'd3) ? {31'b0, op_a < op_b} :
        (dex_f3 == 3'd4) ? (op_a ^ op_b) :
        (dex_f3 == 3'd5) ? (sub_sel ? ($signed(op_a) >>> shamt) : (op_a >> shamt)) :
        (dex_f3 == 3'd6) ? (op_a | op_b) : (op_a & op_b);

    wire beq  = (fwd_a == fwd_b);
    wire bne  = ~beq;
    wire blt  = ($signed(fwd_a) < $signed(fwd_b));
    wire bge  = ~blt;
    wire bltu = (fwd_a < fwd_b);
    wire bgeu = ~bltu;
    wire branch_take = is_branch && (
        (dex_f3 == 3'd0 &  beq)  | (dex_f3 == 3'd1 &  bne)  |
        (dex_f3 == 3'd4 &  blt)  | (dex_f3 == 3'd5 &  bge)  |
        (dex_f3 == 3'd6 &  bltu) | (dex_f3 == 3'd7 &  bgeu));
    wire redirect = branch_take | is_jal | is_jalr;
    wire [31:0] target = is_jal ? (dex_pc + imm_j) :
                         is_jalr ? ((fwd_a + imm_i) & 32'hFFFFFFFE) :
                         (dex_pc + imm_b);

    // ==================== 冒险与控制 ====================
    wire load_use = dex_v && dex_ld && (dex_rd != 0) && ifd_v && id_rd_wr &&
                    ((dex_rd == id_rs1 && id_us1) || (dex_rd == id_rs2 && id_us2));
    wire stall = load_use;
    wire flush = redirect;                 // 冲刷 IF/ID、ID/EX

    // ==================== 数据访问(MEM) ====================
    wire        dmem_we  = exm_v && exm_st;
    wire [31:0] dmem_ad  = exm_alu;
    wire        hit_gpio = (dmem_ad == 32'h1000);
    wire        hit_host = (dmem_ad == 32'h1008);
    reg  [31:0] dmem_rd;
    always @(posedge clk) if (exm_v) begin
        if (dmem_we && !hit_gpio && !hit_host) dmem[dmem_ad[11:2]] <= exm_stv;
        dmem_rd <= dmem[dmem_ad[11:2]];
    end
    // 子字加载提取(f3: 0=lb 1=lh 2=lw 4=lbu 5=lhu)
    wire [1:0]  lane = dmem_ad[1:0];
    reg [31:0] ld_sub;
    always @* begin
        case (exm_f3)
            3'd0: ld_sub = {{24{dmem_rd[lane*8 +: 8]}}, dmem_rd[lane*8 +: 8]};
            3'd1: ld_sub = {{16{dmem_rd[lane*16 +: 16]}}, dmem_rd[lane*16 +: 16]};
            3'd4: ld_sub = {24'b0, dmem_rd[lane*8 +: 8]};
            3'd5: ld_sub = {16'b0, dmem_rd[lane*16 +: 16]};
            default: ld_sub = dmem_rd;
        endcase
    end
    wire [31:0] ld_data = hit_gpio ? gpio_out : ld_sub;

    reg  [31:0] gpio_q;
    reg         tohost_q;
    reg  [31:0] tohost_v;
    initial begin gpio_q = 0; tohost_q = 0; tohost_v = 0; end
    assign gpio_out   = gpio_q;
    assign tohost     = tohost_q;
    assign tohost_val = tohost_v;

    // ==================== 写回 ====================
    wire        rf_we = mwb_v && mwb_wr && (mwb_rd != 5'd0);
    wire [31:0] rf_wd = mwb_ld ? mwb_ldata : mwb_alu;

    // ==================== 退休踪迹 ====================
    assign ret_valid  = mwb_v;
    assign ret_pc     = mwb_pc;
    assign ret_rd     = mwb_rd;
    assign ret_rd_en  = mwb_wr;
    assign ret_wdata  = rf_wd;

    // ==================== 时序 ====================
    always @(posedge clk) begin
        if (rst) begin
            pc <= 0; ifd_v <= 0; dex_v <= 0; exm_v <= 0; mwb_v <= 0;
            gpio_q <= 0; tohost_q <= 0; tohost_v <= 0;
        end else begin
            if (exm_v && exm_st && hit_gpio)  gpio_q <= exm_stv;
            if (exm_v && exm_st && hit_host) begin
                tohost_q <= 1'b1; tohost_v <= exm_stv;
            end

            // ---- EX/MEM ----
            exm_v   <= dex_v;
            exm_pc  <= dex_pc;
            exm_rd  <= dex_rd;
            exm_wr  <= dex_wr;
            exm_ld  <= dex_ld;
            exm_st  <= dex_st;
            exm_f3  <= dex_f3;
            exm_alu <= alu_out;
            exm_stv <= fwd_b;

            // ---- ID/EX ----
            dex_v    <= ifd_v && !stall && !flush;
            dex_pc   <= ifd_pc;
            dex_inst <= ifd_inst;
            dex_rd   <= id_rd;
            dex_wr   <= id_rd_wr;
            dex_ld   <= is_load;
            dex_st   <= is_store;
            dex_br   <= is_branch;
            dex_f3   <= id_f3;
            dex_rs1  <= id_rs1;
            dex_rs2  <= id_rs2;
            dex_rsv1 <= rv1;
            dex_rsv2 <= rv2;

            // ---- IF/ID ----
            ifd_v   <= !flush && !stall;
            ifd_pc  <= pc;
            ifd_inst<= imem_rdata;

            // ---- PC ----
            if (!stall) pc <= redirect ? target : pc_plus4;
        end
    end

    // ==================== 寄存器堆写 ====================
    always @(posedge clk) begin
        if (rf_we) rf[mwb_rd] <= rf_wd;
    end

endmodule
