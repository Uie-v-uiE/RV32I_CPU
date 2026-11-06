// z7_rv32i_board.v — RV32I 五级流水核板级演示顶层(RK-ZYNQ7020-F)。
//   内置 fib 程序(BRAM 初始化),上电跑完 tohost 置位 → LED0 常亮;
//   LED1 = 25-bit 分频闪烁(时钟活性)。复位 = KEY1(低有效,2FF 同步)。
//   功能正确性已由 ISS 踪迹比对(5/5 PASS)保证,板级只验证可运行性。
module z7_rv32i_board (
    input  wire clk,          // W17 50 MHz
    input  wire key1_n,       // W18 按键(低有效)
    output wire led0,         // V15:tohost 完成
    output wire led1          // V13:活性
);
    // 按键同步 + 极性(KEY1 按下 = 0 → rst 高有效)
    reg [1:0] rsync;
    always @(posedge clk) rsync <= {rsync[0], key1_n};
    wire rst = ~rsync[1];

    reg [24:0] blink_cnt;
    always @(posedge clk) blink_cnt <= blink_cnt + 1'b1;

    wire        tohost;
    wire [31:0] gpio_out, tohost_val;
    wire        ret_valid, ret_rd_en;
    wire [31:0] ret_pc, ret_wdata;
    wire [4:0]  ret_rd;

    rv32i_core #(.PROG("prog_fib.hex")) u_core (
        .clk       (clk),
        .rst       (rst),
        .gpio_out  (gpio_out),
        .tohost    (tohost),
        .tohost_val(tohost_val),
        .ret_valid (ret_valid),
        .ret_pc    (ret_pc),
        .ret_rd    (ret_rd),
        .ret_rd_en (ret_rd_en),
        .ret_wdata (ret_wdata)
    );

    reg done;
    always @(posedge clk) begin
        if (rst) done <= 1'b0;
        else if (tohost) done <= 1'b1;
    end

    assign led0 = done;      // fib 跑完 tohost 置位 → 常亮
    assign led1 = blink_cnt[24];
endmodule
