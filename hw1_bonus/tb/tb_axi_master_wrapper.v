// ============================================================================
// Testbench：AXI4 Master Wrapper
// 系統：WB master BFM（扮演 wb_dma 的 DMA 引擎） -> axi_master_wrapper
//       -> axi_mem_model（記憶體控制器，故意先收 W 才給 AWREADY）
// 測項：
//   T1 寫入 + 讀回；確認 W 先完成、AW 後完成時 wrapper 不會死結
//   T2 DMA 搬移：從來源區讀 4 個 word，寫到目的區，再比對
//   T3 寫入 / 讀取錯誤區 (0x8000_0000) -> wb_err
// ============================================================================
`timescale 1ns/1ps
module tb_axi_master_wrapper;
    reg ACLK = 0, ARESETn = 0;
    always #5 ACLK = ~ACLK;

    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    reg  [3:0]  wb_sel = 4'hF;
    wire [31:0] wb_dat_r;
    wire        wb_ack, wb_err;

    wire [3:0]  AWID, ARID;
    wire [31:0] AWADDR, ARADDR, WDATA, RDATA;
    wire [7:0]  AWLEN, ARLEN;
    wire [2:0]  AWSIZE, ARSIZE;
    wire [1:0]  AWBURST, ARBURST, BRESP, RRESP;
    wire [3:0]  WSTRB;
    wire        AWVALID, AWREADY, WVALID, WREADY, WLAST, BVALID, BREADY;
    wire        ARVALID, ARREADY, RVALID, RREADY, RLAST;

    axi_master_wrapper dut (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWID(AWID), .AWADDR(AWADDR), .AWLEN(AWLEN), .AWSIZE(AWSIZE), .AWBURST(AWBURST),
        .AWVALID(AWVALID), .AWREADY(AWREADY),
        .WDATA(WDATA), .WSTRB(WSTRB), .WLAST(WLAST), .WVALID(WVALID), .WREADY(WREADY),
        .BID(4'd0), .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
        .ARID(ARID), .ARADDR(ARADDR), .ARLEN(ARLEN), .ARSIZE(ARSIZE), .ARBURST(ARBURST),
        .ARVALID(ARVALID), .ARREADY(ARREADY),
        .RID(4'd0), .RDATA(RDATA), .RRESP(RRESP), .RLAST(RLAST), .RVALID(RVALID), .RREADY(RREADY),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_sel_i(wb_sel), .wb_dat_i(wb_dat_w),
        .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err)
    );

    axi_mem_model u_mem (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWADDR(AWADDR), .AWVALID(AWVALID), .AWREADY(AWREADY),
        .WDATA(WDATA), .WSTRB(WSTRB), .WVALID(WVALID), .WREADY(WREADY),
        .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
        .ARADDR(ARADDR), .ARVALID(ARVALID), .ARREADY(ARREADY),
        .RDATA(RDATA), .RRESP(RRESP), .RLAST(RLAST), .RVALID(RVALID), .RREADY(RREADY)
    );

    // ---------------- WB master BFM ----------------
    reg [31:0] rd;
    reg        got_err;
    integer    errors = 0;

    task wb_xfer;
        input        we;
        input [31:0] adr, dat;
        begin
            @(posedge ACLK); #1;
            wb_cyc = 1; wb_stb = 1; wb_we = we; wb_adr = adr; wb_dat_w = dat;
            @(negedge ACLK);
            while (!(wb_ack || wb_err)) @(negedge ACLK);
            rd = wb_dat_r; got_err = wb_err;
            @(posedge ACLK); #1;
            wb_cyc = 0; wb_stb = 0; wb_we = 0;
        end
    endtask

    task check;
        input [31:0] got, exp;
        input [8*24-1:0] name;
        begin
            if (got !== exp) begin
                $display("  [FAIL] %0s : got %h, expected %h", name, got, exp);
                errors = errors + 1;
            end else
                $display("  [PASS] %0s : %h", name, got);
        end
    endtask

    // 統計「W 已完成、AW 還在等」的拍數：證明 AW 與 W 是分開完成的
    integer w_first_cycles = 0;
    always @(posedge ACLK) if (dut.state == 3'd1 && dut.w_done && !dut.aw_done)
        w_first_cycles = w_first_cycles + 1;

    integer k;
    initial begin
        $dumpfile("sim/tb_axi_master_wrapper.vcd");
        $dumpvars(0, tb_axi_master_wrapper);
        repeat (2) @(posedge ACLK);
        ARESETn = 1;
        for (k = 0; k < 4; k = k + 1) u_mem.mem[16 + k] = 32'hD0D0_0000 + k;  // 0x40~0x4C

        $display("== T1 寫入 0x00 再讀回（slave 先收 W 才給 AWREADY） ==");
        wb_xfer(1, 32'h0000_0000, 32'h7777_8888);
        wb_xfer(0, 32'h0000_0000, 0);
        check(rd, 32'h7777_8888, "T1 read back");
        if (w_first_cycles > 0)
            $display("  [PASS] T1 W 先完成、AW 等了 %0d 拍，沒有死結", w_first_cycles);
        else begin $display("  [FAIL] T1 沒有觀察到 W 先完成"); errors = errors + 1; end

        $display("== T2 DMA 搬移 0x40~0x4C -> 0x80~0x8C ==");
        for (k = 0; k < 4; k = k + 1) begin
            wb_xfer(0, 32'h0000_0040 + 4 * k, 0);
            wb_xfer(1, 32'h0000_0080 + 4 * k, rd);
        end
        for (k = 0; k < 4; k = k + 1) check(u_mem.mem[32 + k], 32'hD0D0_0000 + k, "T2 dst word");

        $display("== T3 存取錯誤區 0x8000_0000 -> 應收到 wb_err ==");
        wb_xfer(1, 32'h8000_0000, 32'h0);
        check({31'd0, got_err}, 32'd1, "T3 write wb_err");
        wb_xfer(0, 32'h8000_0000, 32'h0);
        check({31'd0, got_err}, 32'd1, "T3 read wb_err");

        repeat (3) @(posedge ACLK);
        if (errors == 0) $display("\n*** tb_axi_master_wrapper : ALL TESTS PASSED ***");
        else             $display("\n*** tb_axi_master_wrapper : %0d TEST(S) FAILED ***", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
