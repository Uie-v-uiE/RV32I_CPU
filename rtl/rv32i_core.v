// rv32i_core.v — RV32I 五级顺序流水核。
//   IF/ID/EX/MEM/WB;双源前递 + load-use 一拍停顿 + 分支两泡冲刷;
//   EX 段全部用 dex_inst(ID/EX 寄存后)译码;redirect/flush 按 dex_v 过滤防 X 泄漏。
//   统一 GPIO(0x1000)/tohost(0x1008) MMIO;哈佛数据区(dmem 1024×32)。
// 验证:golden/rv_iss.py ISS 退休踪迹 1:1 比对(见 tb/tb_rv32i.v)。
module rv32i_core #(
    parameter PROG = "vectors/prog.hex"
)(
    input  wire        clk,
    input  wire        rst,
    output wire [31:0] gpio_out,
    output wire        tohost,
    output wire [31:0] tohost_val,
    output wire        ret_valid,
    output wire [31:0] ret_pc,
    output wire [4:0]  ret_rd,
    output wire        ret_rd_en,
    output wire [31:0] ret_wdata
);
    // ==================== 存储器 ====================
    // 统一 8KB 存储(冯诺依曼,与 ISS/约定一致):低区放程序,数据区从 0x100 起
    (* ram_style = "block" *)
    reg [31:0] umem [0:2047];
    integer zi0;
    initial begin
        for (zi0 = 0; zi0 < 2048; zi0 = zi0 + 1) umem[zi0] = 32'b0;  // 与 ISS 全零初始化一致
        $readmemh(PROG, umem);
    end

    (* ram_style = "distributed" *)
    reg [31:0] rf [1:31];
    integer zi;
    initial begin
        for (zi = 1; zi < 32; zi = zi + 1) rf[zi] = 32'b0;
    end

    // ==================== 级间寄存器 ====================
    reg         ifd_v;
    reg [31:0]  ifd_pc, ifd_inst;
    reg         dex_v;
    reg [31:0]  dex_pc, dex_inst, dex_rsv1, dex_rsv2;
    reg [4:0]   dex_rd, dex_rs1, dex_rs2;
    reg         dex_wr, dex_ld, dex_st;
    reg [2:0]   dex_f3;
    reg         exm_v, exm_wr, exm_ld, exm_st;
    reg [31:0]  exm_pc, exm_alu, exm_stv;
    reg [4:0]   exm_rd;
    reg [2:0]   exm_f3;
    reg         mwb_v, mwb_wr, mwb_ld;
    reg [31:0]  mwb_pc, mwb_alu, mwb_ldata;
    reg [4:0]   mwb_rd;

    // ==================== ID 译码(本级冒险用) ====================
    wire [6:0]  opcode_id = ifd_inst[6:0];
    wire [4:0]  id_rd  = ifd_inst[11:7];
    wire [4:0]  id_rs1 = ifd_inst[19:15];
    wire [4:0]  id_rs2 = ifd_inst[24:20];
    wire        is_load  = (opcode_id == 7'b0000011);
    wire        is_store = (opcode_id == 7'b0100011);
    wire [2:0]  id_f3    = ifd_inst[14:12];
    wire        id_rd_wr = (opcode_id != 7'b0100011) && (opcode_id != 7'b1100011);
    wire        id_us1   = (opcode_id != 7'b0110111) && (opcode_id != 7'b0010111);
    wire        id_us2   = (opcode_id == 7'b0110011) || (opcode_id == 7'b1100011) || (opcode_id == 7'b0100011);

    wire [31:0] rv1 = (id_rs1 == 5'd0) ? 32'b0 : rf[id_rs1];
    wire [31:0] rv2 = (id_rs2 == 5'd0) ? 32'b0 : rf[id_rs2];

    // ==================== IF ====================
    reg  [31:0] pc;
    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] imem_rdata = umem[pc[12:2]];

    // ==================== EX 译码(dex_inst,ID/EX 寄存后) ====================
    wire [6:0]  dex_opcode = dex_inst[6:0];
    wire        ex_is_load  = (dex_opcode == 7'b0000011);
    wire        ex_is_store = (dex_opcode == 7'b0100011);
    wire        ex_is_branch= (dex_opcode == 7'b1100011);
    wire        ex_is_jal   = (dex_opcode == 7'b1101111);
    wire        ex_is_jalr  = (dex_opcode == 7'b1100111);
    wire        ex_is_lui   = (dex_opcode == 7'b0110111);
    wire        ex_is_auipc = (dex_opcode == 7'b0010111);
    wire        ex_is_alui  = (dex_opcode == 7'b0010011);
    wire        ex_is_alur  = (dex_opcode == 7'b0110011);
    wire [2:0]  ex_f3       = dex_inst[14:12];

    // 寄存器堆实时读(兜底前递:WB 写回完成后但 ID 采样值已旧的场景)
    wire [31:0] rf_lv1 = (dex_rs1 == 5'd0) ? 32'b0 : rf[dex_rs1];
    wire [31:0] rf_lv2 = (dex_rs2 == 5'd0) ? 32'b0 : rf[dex_rs2];

    // ==================== 前递 ====================
    wire        exm_fwd_v = exm_v && exm_wr && !exm_ld;   // load 取值未就绪不前递
    wire [31:0] fwd_a = (dex_v && dex_rs1 != 0 && dex_rs1 == exm_rd && exm_fwd_v) ? exm_alu :
                        (dex_v && dex_rs1 != 0 && dex_rs1 == mwb_rd && mwb_v && mwb_wr) ? (mwb_ld ? mwb_ldata : mwb_alu) : rf_lv1;
    wire [31:0] fwd_b = (dex_v && dex_rs2 != 0 && dex_rs2 == exm_rd && exm_fwd_v) ? exm_alu :
                        (dex_v && dex_rs2 != 0 && dex_rs2 == mwb_rd && mwb_v && mwb_wr) ? (mwb_ld ? mwb_ldata : mwb_alu) : rf_lv2;

    // ==================== EX ====================
    wire [31:0] imm_i = {{20{dex_inst[31]}}, dex_inst[31:20]};
    wire [31:0] imm_s = {{20{dex_inst[31]}}, dex_inst[31:25], dex_inst[11:7]};
    wire [31:0] imm_b = {{19{dex_inst[31]}}, dex_inst[31], dex_inst[7], dex_inst[30:25], dex_inst[11:8], 1'b0};
    wire [31:0] imm_u = {dex_inst[31:12], 12'b0};
    wire [31:0] imm_j = {{11{dex_inst[31]}}, dex_inst[31], dex_inst[19:12], dex_inst[20], dex_inst[30:21], 1'b0};

    wire        sub_sel  = dex_inst[30] & (ex_is_alur | (ex_is_alui & (ex_f3 == 3'd5)));
    wire [31:0] op_a     = ex_is_auipc ? dex_pc : fwd_a;
    wire [31:0] op_b     = ex_is_store          ? imm_s :
                           ex_is_branch         ? imm_b :
                           ex_is_alur           ? fwd_b :    // R 型第二操作数 = 寄存器
                           (ex_is_lui | ex_is_auipc) ? imm_u :
                           ex_is_jal            ? imm_j : imm_i;
    wire [4:0]  shamt    = op_b[4:0];
    wire [31:0] sum      = op_a + op_b;
    // 算术右移显式符号填充($signed>>> 在混合 unsigned 的嵌套三元里会被强转逻辑移位)
    wire [31:0] sra_res  = (op_a >> shamt) | ({32{op_a[31]}} << (6'd32 - {1'b0, shamt}));
    wire [31:0] alu_out =
        (ex_is_load | ex_is_store) ? sum :   // load/store 强制地址计算,不进 f3 分派
        ex_is_branch ? 32'b0 :
        ex_is_jal    ? dex_pc + 32'd4 :
        ex_is_jalr   ? dex_pc + 32'd4 :
        ex_is_lui    ? imm_u :
        ex_is_auipc  ? sum :
        (ex_f3 == 3'd0) ? (sub_sel ? (op_a - op_b) : sum) :
        (ex_f3 == 3'd1) ? (op_a << shamt) :
        (ex_f3 == 3'd2) ? {31'b0, $signed(op_a) < $signed(op_b)} :
        (ex_f3 == 3'd3) ? {31'b0, op_a < op_b} :
        (ex_f3 == 3'd4) ? (op_a ^ op_b) :
        (ex_f3 == 3'd5) ? (sub_sel ? sra_res : (op_a >> shamt)) :
        (ex_f3 == 3'd6) ? (op_a | op_b) : (op_a & op_b);

    wire beq  = (fwd_a == fwd_b);
    wire bne  = ~beq;
    wire blt  = ($signed(fwd_a) < $signed(fwd_b));
    wire bge  = ~blt;
    wire bltu = (fwd_a < fwd_b);
    wire bgeu = ~bltu;
    wire branch_take = ex_is_branch && (
        (ex_f3 == 3'd0 &  beq)  | (ex_f3 == 3'd1 &  bne)  |
        (ex_f3 == 3'd4 &  blt)  | (ex_f3 == 3'd5 &  bge)  |
        (ex_f3 == 3'd6 &  bltu) | (ex_f3 == 3'd7 &  bgeu));
    wire redirect = branch_take | ex_is_jal | ex_is_jalr;
    wire [31:0] target = ex_is_jal ? (dex_pc + imm_j) :
                         ex_is_jalr ? ((fwd_a + imm_i) & 32'hFFFFFFFE) :
                         (dex_pc + imm_b);

    // ==================== 冒险与控制 ====================
    wire load_use = dex_v && ex_is_load && (dex_rd != 0) && ifd_v && id_rd_wr &&
                    ((dex_rd == id_rs1 && id_us1) || (dex_rd == id_rs2 && id_us2));
    wire stall = load_use;
    wire flush = dex_v && redirect;        // 仅 EX 有效指令时冲刷,防 X 瞬态污染
    wire en    = !rst;

    // ==================== 数据访问(MEM) ====================
    wire        hit_gpio = (exm_alu == 32'h1000);
    wire        hit_host = (exm_alu == 32'h1008);
    wire        dmem_we  = exm_v && exm_st && !hit_gpio && !hit_host;
    wire [31:0] dmem_rd  = umem[exm_alu[11:2]];  // 组合读(寄存读会与 mwb_ldata 同沿级联,错位一拍)
    wire [1:0]  lane     = exm_alu[1:0];
    wire [7:0]  sb_byte  = exm_stv[7:0];
    wire [15:0] sh_half  = exm_stv[15:0];
    always @(posedge clk) if (exm_v) begin
        if (dmem_we) begin
            // 子字合并整字读改写(dmem[i][part] 切片赋值在 Verilog-2001 非法,ModelSim 静默丢写)
            case (exm_f3[1:0])
                2'b00: umem[exm_alu[11:2]] <=
                       (lane == 2'd0) ? {dmem_rd[31:8],  sb_byte} :
                       (lane == 2'd1) ? {dmem_rd[31:16], sb_byte, dmem_rd[7:0]} :
                       (lane == 2'd2) ? {dmem_rd[31:24], sb_byte, dmem_rd[15:0]} :
                                        {sb_byte, dmem_rd[23:0]};
                2'b01: umem[exm_alu[11:2]] <=
                       lane[1] ? {sh_half, dmem_rd[15:0]} : {dmem_rd[31:16], sh_half};
                default: umem[exm_alu[11:2]] <= exm_stv;
            endcase
        end
    end
    // 子字加载提取(f3: 0=lb 1=lh 2=lw 4=lbu 5=lhu);符号扩展取字段符号位
    wire [7:0]  ld_b = dmem_rd[lane*8 +: 8];
    wire [15:0] ld_h = lane[1] ? dmem_rd[31:16] : dmem_rd[15:0];
    reg  [31:0] ld_sub;
    always @* begin
        case (exm_f3)
            3'd0: ld_sub = {{24{ld_b[7]}}, ld_b};
            3'd1: ld_sub = {{16{ld_h[15]}}, ld_h};
            3'd4: ld_sub = {24'b0, ld_b};
            3'd5: ld_sub = {16'b0, ld_h};
            default: ld_sub = dmem_rd;
        endcase
    end
    wire [31:0] ld_data = hit_gpio ? gpio_out : ld_sub;

    reg  [31:0] gpio_q;
    reg         tohost_q;
    reg  [31:0] tohost_v;
    assign gpio_out   = gpio_q;
    assign tohost     = tohost_q;
    assign tohost_val = tohost_v;

    // ==================== WB ====================
    wire        rf_we = mwb_v && mwb_wr && (mwb_rd != 5'd0);
    wire [31:0] rf_wd = mwb_ld ? mwb_ldata : mwb_alu;

    // ==================== 退休踪迹 ====================
    assign ret_valid  = mwb_v;
    assign ret_pc     = mwb_pc;
    assign ret_rd     = mwb_wr ? mwb_rd : 5'b0;   // 不写回的指令(分支/store)rd 屏蔽为 0
    assign ret_rd_en  = mwb_wr;
    assign ret_wdata  = mwb_wr ? rf_wd : 32'b0;   // 不写回指令 wdata 屏蔽,与 ISS 踪迹约定一致

    // ==================== 级间推进 ====================
    always @(posedge clk) begin
        if (rst) begin
            pc <= 0; ifd_v <= 0; dex_v <= 0; exm_v <= 0; mwb_v <= 0;
            ifd_pc <= 0; ifd_inst <= 32'h00000013;          // NOP 填充防 X
            dex_pc <= 0; dex_inst <= 32'h00000013;
            dex_wr <= 0; dex_ld <= 0; dex_st <= 0;
            gpio_q <= 0; tohost_q <= 0; tohost_v <= 0;
        end else if (en) begin
            // GPIO / tohost
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
            dex_f3   <= id_f3;
            dex_rs1  <= id_rs1;
            dex_rs2  <= id_rs2;
            dex_rsv1 <= rv1;
            dex_rsv2 <= rv2;

            // ---- IF/ID ----
            // stall 拍 IF/ID 整体保持(pc 已指下一条,重读会覆盖被停指令);仅 flush 清有效
            ifd_v    <= !flush && (!stall || ifd_v);
            ifd_pc   <= stall ? ifd_pc : pc;
            ifd_inst <= stall ? ifd_inst : imem_rdata;

            // ---- MEM/WB ----
            mwb_v     <= exm_v;
            mwb_pc    <= exm_pc;
            mwb_rd    <= exm_rd;
            mwb_wr    <= exm_wr;
            mwb_ld    <= exm_ld;
            mwb_alu   <= exm_alu;
            mwb_ldata <= ld_data;

            // ---- PC ----
            if (!stall) pc <= (dex_v && redirect) ? target : pc_plus4;
        end
    end

    // ==================== 寄存器堆写 ====================
    always @(posedge clk) begin
        if (rf_we) rf[mwb_rd] <= rf_wd;
    end

endmodule
