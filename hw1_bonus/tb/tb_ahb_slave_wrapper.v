// ============================================================================
// Testbench：AHB Slave Wrapper
// 系統：AHB master BFM（扮演 CPU） -> ahb_slave_wrapper -> wb_slave_model（wb_dma 暫存器）
// 測項：
//   T1 單筆寫入 + 讀回
//   T2 INCR4 burst 寫入 + INCR4 burst 讀回（展示 pipeline 與等待狀態）
//   T3 存取不存在的暫存器 -> 兩拍 ERROR 回應
//   T4 錯誤之後再存取，確認 wrapper 能恢復
// ============================================================================
`timescale 1ns/1ps
module tb_ahb_slave_wrapper;
    reg         HCLK = 0, HRESETn = 0;
    reg         HSEL = 0;
    reg  [31:0] HADDR = 0, HWDATA = 0;
    reg         HWRITE = 0;
    reg  [1:0]  HTRANS = 0;
    reg  [2:0]  HSIZE = 3'b010, HBURST = 0;
    wire        HREADYOUT;
    wire [1:0]  HRESP;
    wire [31:0] HRDATA;
    wire        HREADY = HREADYOUT;     // 單一 slave：匯流排 HREADY 就是它的 HREADYOUT

    wire        wb_cyc, wb_stb, wb_we, wb_ack, wb_err;
    wire [31:0] wb_adr, wb_dat_w, wb_dat_r;
    wire [3:0]  wb_sel;

    always #5 HCLK = ~HCLK;

    ahb_slave_wrapper dut (
        .HCLK(HCLK), .HRESETn(HRESETn),
        .HSEL(HSEL), .HADDR(HADDR), .HWRITE(HWRITE), .HTRANS(HTRANS),
        .HSIZE(HSIZE), .HWDATA(HWDATA), .HREADY(HREADY),
        .HREADYOUT(HREADYOUT), .HRESP(HRESP), .HRDATA(HRDATA),
        .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we),
        .wb_adr_o(wb_adr), .wb_sel_o(wb_sel), .wb_dat_o(wb_dat_w),
        .wb_dat_i(wb_dat_r), .wb_ack_i(wb_ack), .wb_err_i(wb_err)
    );

    wb_slave_model #(.WAIT(1)) u_wb (
        .clk(HCLK), .rst(~HRESETn),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_sel_i(wb_sel), .wb_dat_i(wb_dat_w),
        .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err)
    );

    // ---------------- AHB master BFM ----------------
    localparam NONSEQ = 2'b10, SEQ = 2'b11, IDLE = 2'b00;
    reg [31:0] wbuf [0:15];
    reg [31:0] rbuf [0:15];
    reg [1:0]  rresp [0:15];
    reg        dp_active, dp_write;
    integer    dp_idx;
    integer    errors = 0;

    // 等待目前的傳輸相位結束（HREADY=1 的那個時脈邊緣），
    // 結束前若有讀取資料相位，順便取回 HRDATA 與 HRESP
    task wait_ready;
        begin
            @(negedge HCLK);
            while (!HREADY) @(negedge HCLK);
            if (dp_active) begin
                rresp[dp_idx] = HRESP;
                if (!dp_write) rbuf[dp_idx] = HRDATA;
            end
            @(posedge HCLK);
        end
    endtask

    // n 拍的 AHB 傳輸：n=1 為 SINGLE，n=4 為 INCR4
    task ahb_xfer;
        input        wr;
        input [31:0] base;
        input integer n;
        integer i;
        begin
            dp_active = 0;
            #1;
            HSEL = 1; HADDR = base; HWRITE = wr; HTRANS = NONSEQ;
            HBURST = (n == 4) ? 3'b011 : 3'b000;
            for (i = 0; i < n; i = i + 1) begin
                wait_ready();           // 第 i 拍的位址相位被接受
                #1;
                dp_active = 1; dp_write = wr; dp_idx = i;
                if (wr) HWDATA = wbuf[i];
                if (i < n - 1) begin HADDR = base + 4 * (i + 1); HTRANS = SEQ; end
                else           begin HTRANS = IDLE; HSEL = 0; end
            end
            wait_ready();               // 最後一拍的資料相位結束
            dp_active = 0;
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
        $dumpfile("sim/tb_ahb_slave_wrapper.vcd");
        $dumpvars(0, tb_ahb_slave_wrapper);
        repeat (2) @(posedge HCLK);
        HRESETn = 1;
        @(posedge HCLK);

        $display("== T1 單筆寫入 CSR(0x00) 再讀回 ==");
        wbuf[0] = 32'h0000_0001;
        ahb_xfer(1, 32'h0000_0000, 1);
        ahb_xfer(0, 32'h0000_0000, 1);
        check(rbuf[0], 32'h0000_0001, "T1 read CSR");

        $display("== T2 INCR4 burst 寫入 0x20~0x2C 再 burst 讀回 ==");
        for (k = 0; k < 4; k = k + 1) wbuf[k] = 32'hA5A5_0000 + k;
        ahb_xfer(1, 32'h0000_0020, 4);
        ahb_xfer(0, 32'h0000_0020, 4);
        for (k = 0; k < 4; k = k + 1) check(rbuf[k], 32'hA5A5_0000 + k, "T2 burst read");
        // 直接檢查暫存器內容，確認每一拍寫到正確位址
        for (k = 0; k < 4; k = k + 1) check(u_wb.regs[8 + k], 32'hA5A5_0000 + k, "T2 reg file");

        $display("== T3 讀取不存在的暫存器 0x200 -> 應回 ERROR ==");
        ahb_xfer(0, 32'h0000_0200, 1);
        check({30'd0, rresp[0]}, 32'd1, "T3 HRESP=ERROR");

        $display("== T4 錯誤之後再寫入/讀回 0x04 ==");
        wbuf[0] = 32'h1234_5678;
        ahb_xfer(1, 32'h0000_0004, 1);
        ahb_xfer(0, 32'h0000_0004, 1);
        check(rbuf[0], 32'h1234_5678, "T4 read after error");

        repeat (3) @(posedge HCLK);
        if (errors == 0) $display("\n*** tb_ahb_slave_wrapper : ALL TESTS PASSED ***");
        else             $display("\n*** tb_ahb_slave_wrapper : %0d TEST(S) FAILED ***", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
