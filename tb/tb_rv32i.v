// tb_rv32i.v — RV32I 核退休踪迹比对 TB。
// +PROG=<hex> +TRACE=<hex>(ISS 踪迹:每退休指令 3 字:pc / wdata / {rd_en,rd})
// 比对:RTL WB 级每条退休 (pc, rd_en, rd, wdata) 与 ISS 1:1;错误>0 即 FAIL。
`timescale 1ns/1ps
module tb_rv32i;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    wire [31:0] gpio_out;
    wire        tohost;
    wire [31:0] tohost_val;
    wire        ret_valid, ret_rd_en;
    wire [31:0] ret_pc, ret_wdata;
    wire [4:0]  ret_rd;

    rv32i_core #(.PROG("vectors/prog.hex")) dut (
        .clk, .rst, .gpio_out, .tohost, .tohost_val,
        .ret_valid, .ret_pc, .ret_rd, .ret_rd_en, .ret_wdata
    );

    localparam MAXT = 65536;
    reg [31:0] exp_mem [0:3*MAXT-1];
    reg [31:0] got_mem [0:3*MAXT-1];
    integer n_exp, n_got;

    initial n_got = 0;
    always @(posedge clk) begin
        if (!rst && ret_valid && n_got < 3*MAXT) begin
            got_mem[n_got]      <= ret_pc;
            got_mem[n_got+1]    <= ret_wdata;
            got_mem[n_got+2]    <= {31'b0, ret_rd_en, ret_rd};
            n_got <= n_got + 3;
        end
    end

    integer i, errors, fd, code, n, dbg;
    reg [1023:0] tracefile;
    reg [31:0] w;

    initial begin
        if (!$value$plusargs("TRACE=%s", tracefile))
            tracefile = "vectors/trace_fib.hex";
        fd = $fopen(tracefile, "r");
        if (fd == 0) begin $display("RV FAIL: open %0s", tracefile); $finish; end
        n_exp = 0;
        code = 1;
        while (code == 1 && n_exp < 3*MAXT) begin
            code = $fscanf(fd, "%h", w);
            if (code == 1) begin
                exp_mem[n_exp] = w;
                n_exp = n_exp + 1;
            end
        end
        $fclose(fd);
        $display("RV: expect %0d words (%0d retires)", n_exp, n_exp/3);

        repeat (6) @(posedge clk);
        rst = 0;

        // 等 tohost 或超时
        i = 0;
        dbg = 0;
        while (!tohost && i < 400000) begin
            @(posedge clk);
            i = i + 1;
            if (dut.dex_v && dut.dex_pc == 32'h14)
                $display("EXDBG t=%0t rsv1=%0d rsv2=%0d fwd_a=%0d fwd_b=%0d alu=%0d dex_pc=%h",
                         $time, dut.dex_rsv1, dut.dex_rsv2, dut.fwd_a, dut.fwd_b,
                         dut.alu_out, dut.dex_pc);
        end
        if (!tohost) $display("RV WARN: tohost 未写,按超时比对");
        $display("RFDBG a0=%h a1=%h a2=%h a3=%h a4=%h",
                 dut.rf[10], dut.rf[11], dut.rf[12], dut.rf[13], dut.rf[14]);
        $display("RFHIST pc=%h w=%b rd=%b wd=%h",
                 dut.mwb_pc, dut.mwb_wr, dut.mwb_rd, dut.rf_wd);

        repeat (8) @(posedge clk);   // 流水排空

        if (n_got < n_exp) begin
            $display("RV FAIL: retired %0d < expected %0d", n_got/3, n_exp/3);
            $finish;
        end
        errors = 0;
        for (i = 0; i < n_exp; i = i + 1) begin
            if (got_mem[i] !== exp_mem[i]) begin
                if (errors < 8)
                    $display("RV mismatch idx=%0d (retire %0d, field %0d): got %h exp %h",
                             i, i/3, i%3, got_mem[i], exp_mem[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("RV32I SELF-CHECK PASS (%0d retires, gpio=%h)", n_exp/3, gpio_out);
        else
            $display("RV32I SELF-CHECK FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
