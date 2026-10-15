// ============================================================================
// AXI4 Master Wrapper  (Wishbone -> AXI4 協定)
// ----------------------------------------------------------------------------
// 用途：wb_dma 的 DMA 引擎用 Wishbone master 發出讀寫，本 wrapper 依 WE
//       走寫入通道 (AW + W + B) 或讀取通道 (AR + R)。
//
// 重點：AXI 規範禁止 master 等 AWREADY 才拉 WVALID（slave 可能先等 WVALID
//       才給 AWREADY，互等就死結），所以 W_SEND 狀態同時拉高 AWVALID 與
//       WVALID，用 aw_done / w_done 兩個旗標記錄誰先完成。
//
// FSM（對應作業第 6 步的狀態圖）：
//   IDLE   : 等 Wishbone 請求，依 WE 分流
//   W_SEND : AWVALID、WVALID 同時拉高，兩個握手都完成才離開
//   W_RESP : BREADY=1，等 BVALID
//   R_ADDR : ARVALID=1，等 ARREADY
//   R_DATA : RREADY=1，等 RVALID
// ============================================================================
module axi_master_wrapper #(
    parameter ID_W = 4
)(
    input  wire            ACLK,
    input  wire            ARESETn,
    // ---------------- AXI 寫入位址通道 AW ----------------
    output wire [ID_W-1:0] AWID,
    output wire [31:0]     AWADDR,
    output wire [7:0]      AWLEN,
    output wire [2:0]      AWSIZE,
    output wire [1:0]      AWBURST,
    output wire            AWVALID,
    input  wire            AWREADY,
    // ---------------- AXI 寫入資料通道 W ----------------
    output wire [31:0]     WDATA,
    output wire [3:0]      WSTRB,
    output wire            WLAST,
    output wire            WVALID,
    input  wire            WREADY,
    // ---------------- AXI 寫入回應通道 B ----------------
    input  wire [ID_W-1:0] BID,
    input  wire [1:0]      BRESP,
    input  wire            BVALID,
    output wire            BREADY,
    // ---------------- AXI 讀取位址通道 AR ----------------
    output wire [ID_W-1:0] ARID,
    output wire [31:0]     ARADDR,
    output wire [7:0]      ARLEN,
    output wire [2:0]      ARSIZE,
    output wire [1:0]      ARBURST,
    output wire            ARVALID,
    input  wire            ARREADY,
    // ---------------- AXI 讀取資料通道 R ----------------
    input  wire [ID_W-1:0] RID,
    input  wire [31:0]     RDATA,
    input  wire [1:0]      RRESP,
    input  wire            RLAST,
    input  wire            RVALID,
    output wire            RREADY,
    // ---------------- Wishbone slave 介面（接 wb_dma 的 master 埠） -------
    input  wire            wb_cyc_i,
    input  wire            wb_stb_i,
    input  wire            wb_we_i,
    input  wire [31:0]     wb_adr_i,
    input  wire [3:0]      wb_sel_i,
    input  wire [31:0]     wb_dat_i,
    output wire [31:0]     wb_dat_o,
    output wire            wb_ack_o,
    output wire            wb_err_o
);

    localparam S_IDLE   = 3'd0,
               S_W_SEND = 3'd1,
               S_W_RESP = 3'd2,
               S_R_ADDR = 3'd3,
               S_R_DATA = 3'd4;

    reg [2:0] state, next_state;
    reg       aw_done, w_done;

    wire wb_req = wb_cyc_i & wb_stb_i;
    wire aw_hs  = AWVALID & AWREADY;
    wire w_hs   = WVALID  & WREADY;
    // AW、W 兩個握手都完成（可以是之前完成的，也可以是這一拍同時完成）
    wire both_done = (aw_done | aw_hs) & (w_done | w_hs);

    // ---------------- 狀態暫存器 ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) state <= S_IDLE;
        else          state <= next_state;
    end

    // ---------------- 次態邏輯 ----------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:   if (wb_req)    next_state = wb_we_i ? S_W_SEND   // ①
                                                          : S_R_ADDR;  // ④
            S_W_SEND: if (both_done) next_state = S_W_RESP;            // ②
            S_W_RESP: if (BVALID)    next_state = S_IDLE;              // ③
            S_R_ADDR: if (ARREADY)   next_state = S_R_DATA;            // ⑤
            S_R_DATA: if (RVALID)    next_state = S_IDLE;              // ⑥
            default:                 next_state = S_IDLE;
        endcase
    end

    // ---------------- aw_done / w_done 旗標 ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            aw_done <= 1'b0;
            w_done  <= 1'b0;
        end else if (state == S_W_SEND) begin
            if (aw_hs) aw_done <= 1'b1;
            if (w_hs)  w_done  <= 1'b1;
        end else begin
            aw_done <= 1'b0;   // 離開 W_SEND 後清除，下一筆重新開始
            w_done  <= 1'b0;
        end
    end

    // ---------------- AXI 輸出 ----------------
    // Wishbone 會保持位址與資料直到 ACK，所以直接接線；也自然滿足
    // 「VALID 拉高後在握手前內容不能變」的 AXI 規則
    assign AWID    = {ID_W{1'b0}};
    assign AWADDR  = wb_adr_i;
    assign AWLEN   = 8'd0;          // 單拍
    assign AWSIZE  = 3'b010;        // 4 bytes
    assign AWBURST = 2'b01;         // INCR
    assign AWVALID = (state == S_W_SEND) & ~aw_done;

    assign WDATA   = wb_dat_i;
    assign WSTRB   = wb_sel_i;
    assign WLAST   = 1'b1;
    assign WVALID  = (state == S_W_SEND) & ~w_done;

    assign BREADY  = (state == S_W_RESP);

    assign ARID    = {ID_W{1'b0}};
    assign ARADDR  = wb_adr_i;
    assign ARLEN   = 8'd0;
    assign ARSIZE  = 3'b010;
    assign ARBURST = 2'b01;
    assign ARVALID = (state == S_R_ADDR);

    assign RREADY  = (state == S_R_DATA);

    // ---------------- Wishbone 輸出 ----------------
    // RESP[1]=0 代表 OKAY/EXOKAY，RESP[1]=1 代表 SLVERR/DECERR
    assign wb_dat_o = RDATA;
    assign wb_ack_o = ((state == S_W_RESP) & BVALID & ~BRESP[1]) |
                      ((state == S_R_DATA) & RVALID & ~RRESP[1]);
    assign wb_err_o = ((state == S_W_RESP) & BVALID &  BRESP[1]) |
                      ((state == S_R_DATA) & RVALID &  RRESP[1]);

endmodule
