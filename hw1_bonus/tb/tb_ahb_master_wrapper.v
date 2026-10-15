// ============================================================================
// Testbench：AHB Master Wrapper
// 系統：WB master BFM（扮演 wb_dma 的 DMA 引擎） -> ahb_master_wrapper
//       -> AHB 匯流排（含仲裁器，另有一個 CPU master 會搶匯流排）
//       -> ahb_mem_model（記憶體控制器）
// 測項：
//   T1 CPU 正在用匯流排時 DMA 發出寫入 -> wrapper 停在 BUS_REQ 等授權
//   T2 DMA 搬移：從來源區讀 4 個 word，寫到目的區，再比對
//   T3 寫入錯誤區 (0x8000_0000) -> wb_err
//   T4 讀取 RETRY 區 (0x4000_0000) -> wrapper 重新申請匯流排並重送
// ============================================================================
`timescale 1ns/1ps
module tb_ahb_master_wrapper;
    reg HCLK = 0, HRESETn = 0;
    always #5 HCLK = ~HCLK;

    // ---------------- WB master BFM 訊號 ----------------
    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    reg  [3:0]  wb_sel = 4'hF;
    wire [31:0] wb_dat_r;
    wire        wb_ack, wb_err;

    // ---------------- wrapper 的 AHB 訊號 ----------------
    wire        m_HBUSREQ;
    wire [31:0] m_HADDR, m_HWDATA;
    wire [1:0]  m_HTRANS;
    wire        m_HWRITE;
    wire [2:0]  m_HSIZE, m_HBURST;

    // ---------------- 匯流排 ----------------
    wire        HREADY;
    wire [1:0]  HRESP;
    wire [31:0] HRDATA;
    reg         HGRANT_dma = 0;     // 給 wrapper 的授權
    reg         owner_dma  = 0;     // 目前位址匯流排擁有者（1 = DMA，0 = CPU）
    reg         cpu_req    = 0;     // CPU 想用匯流排

    // 仲裁器：CPU 優先；授權只在 HREADY=1 時改變（AHB 規則）
    always @(posedge HCLK) begin
        if (!HRESETn) begin
            HGRANT_dma <= 0; owner_dma <= 0;
        end else if (HREADY) begin
            HGRANT_dma <= m_HBUSREQ & ~cpu_req;
            owner_dma  <= HGRANT_dma;     // 拿到授權的下一拍才擁有位址匯流排
        end
    end

    // 位址/控制多工器（CPU 這裡只佔用匯流排、送 IDLE 傳輸）
    wire [31:0] HADDR  = owner_dma ? m_HADDR  : 32'h0;
    wire [1:0]  HTRANS = owner_dma ? m_HTRANS : 2'b00;
    wire        HWRITE = owner_dma ? m_HWRITE : 1'b0;
    wire [2:0]  HSIZE  = owner_dma ? m_HSIZE  : 3'b010;
    wire [31:0] HWDATA = m_HWDATA;

    ahb_master_wrapper dut (
        .HCLK(HCLK), .HRESETn(HRESETn),
        .HBUSREQ(m_HBUSREQ), .HGRANT(HGRANT_dma), .HREADY(HREADY),
        .HRESP(HRESP), .HRDATA(HRDATA),
        .HADDR(m_HADDR), .HTRANS(m_HTRANS), .HWRITE(m_HWRITE),
        .HSIZE(m_HSIZE), .HBURST(m_HBURST), .HWDATA(m_HWDATA),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_sel_i(wb_sel), .wb_dat_i(wb_dat_w),
        .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err)
    );

    ahb_mem_model #(.WAIT(1)) u_mem (
        .HCLK(HCLK), .HRESETn(HRESETn),
        .HSEL(1'b1), .HADDR(HADDR), .HWRITE(HWRITE), .HTRANS(HTRANS),
        .HSIZE(HSIZE), .HWDATA(HWDATA), .HREADY(HREADY),
        .HREADYOUT(HREADY), .HRESP(HRESP), .HRDATA(HRDATA)
    );

    // ---------------- WB master BFM ----------------
    reg [31:0] rd;
    reg        got_err;
    integer    errors = 0;

    task wb_xfer;
        input        we;
        input [31:0] adr, dat;
        begin
            @(posedge HCLK); #1;
            wb_cyc = 1; wb_stb = 1; wb_we = we; wb_adr = adr; wb_dat_w = dat;
            @(negedge HCLK);
            while (!(wb_ack || wb_err)) @(negedge HCLK);
            rd = wb_dat_r; got_err = wb_err;
            @(posedge HCLK); #1;
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

    integer k, req_cycles;
    // 統計 wrapper 在 BUS_REQ 等了幾拍
    always @(posedge HCLK) if (dut.state == 2'd1) req_cycles = req_cycles + 1;
    // 統計 DATA -> BUS_REQ（⑤ RETRY/SPLIT 重新申請）發生幾次
    integer retry_cnt = 0;
    always @(posedge HCLK) if (dut.state == 2'd3 && dut.next_state == 2'd1) retry_cnt = retry_cnt + 1;

    initial begin
        $dumpfile("sim/tb_ahb_master_wrapper.vcd");
        $dumpvars(0, tb_ahb_master_wrapper);
        // 預先放好 DMA 來源資料
        for (k = 0; k < 4; k = k + 1) u_mem.mem[16 + k] = 32'hC0DE_0000 + k;   // 0x40~0x4C
        req_cycles = 0;
        repeat (2) @(posedge HCLK);
        HRESETn = 1;
        for (k = 0; k < 4; k = k + 1) u_mem.mem[16 + k] = 32'hC0DE_0000 + k;

        $display("== T1 CPU 佔用匯流排時，DMA 寫入 0x00 ==");
        cpu_req = 1;
        fork
            wb_xfer(1, 32'h0000_0000, 32'h1111_2222);
            begin repeat (6) @(posedge HCLK); cpu_req = 0; end   // CPU 6 拍後放手
        join
        check(u_mem.mem[0], 32'h1111_2222, "T1 mem[0x00]");
        if (req_cycles >= 4) $display("  [PASS] T1 wrapper 在 BUS_REQ 等了 %0d 拍", req_cycles);
        else begin $display("  [FAIL] T1 沒有等授權 (%0d 拍)", req_cycles); errors = errors + 1; end

        $display("== T2 DMA 搬移 0x40~0x4C -> 0x80~0x8C ==");
        for (k = 0; k < 4; k = k + 1) begin
            wb_xfer(0, 32'h0000_0040 + 4 * k, 0);
            wb_xfer(1, 32'h0000_0080 + 4 * k, rd);
        end
        for (k = 0; k < 4; k = k + 1) check(u_mem.mem[32 + k], 32'hC0DE_0000 + k, "T2 dst word");

        $display("== T3 寫入錯誤區 0x8000_0000 -> 應收到 wb_err ==");
        wb_xfer(1, 32'h8000_0000, 32'hFFFF_FFFF);
        check({31'd0, got_err}, 32'd1, "T3 wb_err");

        $display("== T4 讀取 RETRY 區 0x4000_0010 -> wrapper 應重送 ==");
        u_mem.mem[4] = 32'h5EED_BEEF;
        wb_xfer(0, 32'h4000_0010, 0);
        check(rd, 32'h5EED_BEEF, "T4 read after RETRY");
        check({31'd0, got_err}, 32'd0, "T4 no error");
        check(retry_cnt, 32'd1, "T4 retry count");

        repeat (3) @(posedge HCLK);
        if (errors == 0) $display("\n*** tb_ahb_master_wrapper : ALL TESTS PASSED ***");
        else             $display("\n*** tb_ahb_master_wrapper : %0d TEST(S) FAILED ***", errors);
        $finish;
    end

    initial begin #20000; $display("TIMEOUT"); $finish; end
endmodule
