// ============================================================================
// AXI4 slave 行為模型：模擬記憶體控制器（單拍傳輸）
// ----------------------------------------------------------------------------
// - 256 words 記憶體（位址取 [9:2]）
// - 故意設計成「先收完 W 才給 AWREADY」：這是 AXI 規範允許 slave 做的事，
//   如果 master 等 AWREADY 才送 WVALID，就會在這裡死結。用來驗證 master
//   wrapper 有同時送出 AW 與 W。
// - B、R 回應都會延遲 1 拍才給，展示 master 等待 VALID 的行為
// - 位址 0x8000_0000 以上回 SLVERR
// ============================================================================
module axi_mem_model (
    input  wire        ACLK,
    input  wire        ARESETn,
    input  wire [31:0] AWADDR,
    input  wire        AWVALID,
    output reg         AWREADY,
    input  wire [31:0] WDATA,
    input  wire [3:0]  WSTRB,
    input  wire        WVALID,
    output reg         WREADY,
    output reg  [1:0]  BRESP,
    output reg         BVALID,
    input  wire        BREADY,
    input  wire [31:0] ARADDR,
    input  wire        ARVALID,
    output reg         ARREADY,
    output reg  [31:0] RDATA,
    output reg  [1:0]  RRESP,
    output reg         RLAST,
    output reg         RVALID,
    input  wire        RREADY
);
    reg [31:0] mem [0:255];
    reg [31:0] waddr, raddr;
    reg        aw_got, w_got, b_pend, r_pend;
    reg [31:0] wdata_q;
    reg [3:0]  wstrb_q;
    integer i;

    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            AWREADY <= 0; WREADY <= 0; BVALID <= 0; BRESP <= 0;
            ARREADY <= 0; RVALID <= 0; RDATA <= 0; RRESP <= 0; RLAST <= 0;
            aw_got <= 0; w_got <= 0; b_pend <= 0; r_pend <= 0;
            waddr <= 0; raddr <= 0; wdata_q <= 0; wstrb_q <= 0;
            for (i = 0; i < 256; i = i + 1) mem[i] <= 32'h0;
        end else begin
            // ---------------- 寫入 ----------------
            // 先收寫入資料，W 握手完成後才給 AWREADY（slave 合法行為）。
            // 若 master 等 AWREADY 才送 WVALID，這裡就會永遠等不到 -> 死結
            WREADY  <= !w_got  && !WREADY  && WVALID;
            AWREADY <= !aw_got && !AWREADY && AWVALID && w_got;
            if (AWVALID && AWREADY) begin aw_got <= 1; waddr <= AWADDR; end
            if (WVALID  && WREADY)  begin w_got  <= 1; wdata_q <= WDATA; wstrb_q <= WSTRB; end

            if (aw_got && w_got && !b_pend && !BVALID) begin
                b_pend <= 1;                       // 延遲一拍再送 B
                if (!waddr[31]) begin
                    if (wstrb_q[0]) mem[waddr[9:2]][7:0]   <= wdata_q[7:0];
                    if (wstrb_q[1]) mem[waddr[9:2]][15:8]  <= wdata_q[15:8];
                    if (wstrb_q[2]) mem[waddr[9:2]][23:16] <= wdata_q[23:16];
                    if (wstrb_q[3]) mem[waddr[9:2]][31:24] <= wdata_q[31:24];
                end
            end
            if (b_pend) begin
                b_pend <= 0;
                BVALID <= 1;
                BRESP  <= waddr[31] ? 2'b10 : 2'b00;
            end
            if (BVALID && BREADY) begin
                BVALID <= 0; aw_got <= 0; w_got <= 0;
            end

            // ---------------- 讀取 ----------------
            ARREADY <= !ARREADY && ARVALID && !r_pend && !RVALID;
            if (ARVALID && ARREADY) begin raddr <= ARADDR; r_pend <= 1; end
            if (r_pend) begin                       // 延遲一拍再送 R
                r_pend <= 0;
                RVALID <= 1; RLAST <= 1;
                RDATA  <= raddr[31] ? 32'hDEAD_BEEF : mem[raddr[9:2]];
                RRESP  <= raddr[31] ? 2'b10 : 2'b00;
            end
            if (RVALID && RREADY) begin RVALID <= 0; RLAST <= 0; end
        end
    end
endmodule
