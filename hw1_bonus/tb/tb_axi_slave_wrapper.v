// ============================================================================
// Testbench：AXI4 Slave Wrapper
// 系統：AXI master BFM（扮演 CPU） -> axi_slave_wrapper -> wb_slave_model（wb_dma 暫存器）
// 測項：
//   T1 單拍寫入 + 讀回
//   T2 4 拍 INCR burst 寫入 + 4 拍 burst 讀回（讀取時第 2 拍 RREADY 故意晚給）
//   T3 存取不存在的暫存器 -> BRESP / RRESP = SLVERR
//   T4 同一拍同時送 AW 與 AR -> wrapper 應先服務寫入，讀回的是新值
// ============================================================================
`timescale 1ns/1ps
module tb_axi_slave_wrapper;
    reg ACLK = 0, ARESETn = 0;
    always #5 ACLK = ~ACLK;

    reg  [3:0]  AWID = 0, ARID = 0;
    reg  [31:0] AWADDR = 0, ARADDR = 0, WDATA = 0;
    reg  [7:0]  AWLEN = 0, ARLEN = 0;
    reg  [2:0]  AWSIZE = 3'b010, ARSIZE = 3'b010;
    reg  [1:0]  AWBURST = 2'b01, ARBURST = 2'b01;
    reg         AWVALID = 0, WVALID = 0, WLAST = 0, BREADY = 0, ARVALID = 0, RREADY = 0;
    reg  [3:0]  WSTRB = 4'hF;
    wire        AWREADY, WREADY, BVALID, ARREADY, RVALID, RLAST;
    wire [3:0]  BID, RID;
    wire [1:0]  BRESP, RRESP;
    wire [31:0] RDATA;

    wire        wb_cyc, wb_stb, wb_we, wb_ack, wb_err;
    wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
    wire [3:0]  wb_sel;

    axi_slave_wrapper dut (
        .ACLK(ACLK), .ARESETn(ARESETn),
        .AWID(AWID), .AWADDR(AWADDR), .AWLEN(AWLEN), .AWSIZE(AWSIZE), .AWBURST(AWBURST),
        .AWVALID(AWVALID), .AWREADY(AWREADY),
        .WDATA(WDATA), .WSTRB(WSTRB), .WLAST(WLAST), .WVALID(WVALID), .WREADY(WREADY),
        .BID(BID), .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
        .ARID(ARID), .ARADDR(ARADDR), .ARLEN(ARLEN), .ARSIZE(ARSIZE), .ARBURST(ARBURST),
        .ARVALID(ARVALID), .ARREADY(ARREADY),
        .RID(RID), .RDATA(RDATA), .RRESP(RRESP), .RLAST(RLAST), .RVALID(RVALID), .RREADY(RREADY),
        .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we),
        .wb_adr_o(wb_adr), .wb_sel_o(wb_sel), .wb_dat_o(wb_dat_w),
        .wb_dat_i(wb_dat_r), .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    wb_slave_model #(.WAIT(1)) u_wb (
        .clk(ACLK), .rst(~ARESETn),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_sel_i(wb_sel), .wb_dat_i(wb_dat_w),
        .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err)
    );

    // ---------------- AXI master BFM ----------------
    reg [31:0] wbuf [0:15];
    reg [31:0] rbuf [0:15];
    reg [1:0]  bresp_got;
    reg [1:0]  rresp_got [0:15];
    reg        rlast_ok;
    integer    errors = 0;
    integer    t_write_done, t_read_addr;   // 記錄時間，用來判斷 T4 的先後順序

    // n 拍寫入：AW 與 W 同時開始送（fork），兩邊都完成後收 B
    task axi_write;
        input [31:0] base;
        input integer n;
        input [3:0] id;
        integer i;
        begin
            @(posedge ACLK); #1;
            fork
                begin   // AW 通道
                    AWVALID = 1; AWADDR = base; AWLEN = n - 1; AWID = id;
                    @(negedge ACLK); while (!AWREADY) @(negedge ACLK);
                    @(posedge ACLK); #1; AWVALID = 0;
                end
                begin   // W 通道
                    for (i = 0; i < n; i = i + 1) begin
                        WVALID = 1; WDATA = wbuf[i]; WLAST = (i == n - 1);
                        @(negedge ACLK); while (!WREADY) @(negedge ACLK);
                        @(posedge ACLK); #1;
                    end
                    WVALID = 0; WLAST = 0;
                end
            join
            BREADY = 1;          // B 通道
            @(negedge ACLK); while (!BVALID) @(negedge ACLK);
            bresp_got = BRESP;
            if (BID !== id) begin $display("  [FAIL] BID mismatch"); errors = errors + 1; end
            @(posedge ACLK); t_write_done = $time; #1; BREADY = 0;
        end
    endtask

    // n 拍讀取；slow_beat >= 0 時，該拍的 RREADY 會晚 6 拍才給（展示 backpressure）
    task axi_read;
        input [31:0] base;
        input integer n;
        input integer slow_beat;
        integer i;
        begin
            @(posedge ACLK); #1;
            ARVALID = 1; ARADDR = base; ARLEN = n - 1; ARID = 4'd5;
            @(negedge ACLK); while (!ARREADY) @(negedge ACLK);
            @(posedge ACLK); t_read_addr = $time; #1; ARVALID = 0;
            rlast_ok = 1;
            for (i = 0; i < n; i = i + 1) begin
                if (i == slow_beat) begin RREADY = 0; repeat (6) @(posedge ACLK); #1; end
                RREADY = 1;
                @(negedge ACLK); while (!RVALID) @(negedge ACLK);
                rbuf[i] = RDATA; rresp_got[i] = RRESP;
                if (RLAST !== (i == n - 1)) rlast_ok = 0;
                @(posedge ACLK); #1;
            end
            RREADY = 0;
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

    integer k;
    initial begin
        $dumpfile("sim/tb_axi_slave_wrapper.vcd");
        $dumpvars(0, tb_axi_slave_wrapper);
        repeat (2) @(posedge ACLK);
        ARESETn = 1;

        $display("== T1 單拍寫入 0x08 再讀回 ==");
        wbuf[0] = 32'hCAFE_0008;
        axi_write(32'h08, 1, 4'd1);
        axi_read (32'h08, 1, -1);
        check(rbuf[0], 32'hCAFE_0008, "T1 read");
        check({30'd0, bresp_got}, 0, "T1 BRESP=OKAY");

        $display("== T2 4 拍 burst 寫入 0x40~0x4C，再 burst 讀回 ==");
        for (k = 0; k < 4; k = k + 1) wbuf[k] = 32'hB0B0_0000 + k;
        axi_write(32'h40, 4, 4'd2);
        axi_read (32'h40, 4, 1);
        for (k = 0; k < 4; k = k + 1) check(rbuf[k], 32'hB0B0_0000 + k, "T2 burst read");
        check({31'd0, rlast_ok}, 1, "T2 RLAST only last");
        // 直接檢查暫存器內容，確認 wrapper 有自己遞增位址（不是全寫到同一格）
        for (k = 0; k < 4; k = k + 1) check(u_wb.regs[16 + k], 32'hB0B0_0000 + k, "T2 reg file");

        $display("== T3 存取不存在的暫存器 0x300 -> SLVERR ==");
        wbuf[0] = 32'h0;
        axi_write(32'h300, 1, 4'd3);
        check({30'd0, bresp_got}, 32'd2, "T3 BRESP=SLVERR");
        axi_read(32'h300, 1, -1);
        check({30'd0, rresp_got[0]}, 32'd2, "T3 RRESP=SLVERR");

        $display("== T4 同一拍送 AW 與 AR（位址 0x10）-> 寫入優先 ==");
        wbuf[0] = 32'hF1F1_0010;
        fork
            axi_write(32'h10, 1, 4'd4);
            axi_read (32'h10, 1, -1);
        join
        check(rbuf[0], 32'hF1F1_0010, "T4 read sees new data");
        if (t_read_addr >= t_write_done) $display("  [PASS] T4 讀取在寫入完成後才被接受");
        else begin $display("  [FAIL] T4 順序錯誤"); errors = errors + 1; end

        repeat (3) @(posedge ACLK);
        if (errors == 0) $display("\n*** tb_axi_slave_wrapper : ALL TESTS PASSED ***");
        else             $display("\n*** tb_axi_slave_wrapper : %0d TEST(S) FAILED ***", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
