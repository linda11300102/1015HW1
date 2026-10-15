// ============================================================================
// AXI4 Slave Wrapper  (AXI4 協定 -> Wishbone)
// ----------------------------------------------------------------------------
// 用途：CPU（AXI master）讀寫 wb_dma 的控制暫存器時，本 wrapper 接收 AXI
//       傳輸（支援 burst），逐拍轉成 Wishbone classic cycle。
//
// 因為 wb_dma 的 Wishbone slave 只有一個埠，讀寫必須序列化，
// 所以讀、寫兩條路徑共用一個 IDLE，兩邊同時有請求時寫入優先。
//
// FSM（對應作業第 5 步的狀態圖）：
//   IDLE   : AWREADY=1；AWVALID=0 時 ARREADY=1
//   W_DATA : WVALID=1 時發 Wishbone 寫入，ACK 回來才拉 WREADY
//   W_RESP : BVALID=1 送寫入回應
//   R_WB   : 發 Wishbone 讀取，等 ACK
//   R_DATA : RVALID=1 送讀取資料，最後一拍 RLAST=1
//
// 簡化假設：資料寬度 32 bit、支援 FIXED/INCR burst（WRAP 當 INCR 處理）、
//          一次只處理一筆交易（不支援 outstanding）。
// ============================================================================
module axi_slave_wrapper #(
    parameter ID_W = 4
)(
    input  wire            ACLK,
    input  wire            ARESETn,
    // ---------------- AXI 寫入位址通道 AW ----------------
    input  wire [ID_W-1:0] AWID,
    input  wire [31:0]     AWADDR,
    input  wire [7:0]      AWLEN,
    input  wire [2:0]      AWSIZE,
    input  wire [1:0]      AWBURST,
    input  wire            AWVALID,
    output wire            AWREADY,
    // ---------------- AXI 寫入資料通道 W ----------------
    input  wire [31:0]     WDATA,
    input  wire [3:0]      WSTRB,
    input  wire            WLAST,
    input  wire            WVALID,
    output wire            WREADY,
    // ---------------- AXI 寫入回應通道 B ----------------
    output wire [ID_W-1:0] BID,
    output wire [1:0]      BRESP,
    output wire            BVALID,
    input  wire            BREADY,
    // ---------------- AXI 讀取位址通道 AR ----------------
    input  wire [ID_W-1:0] ARID,
    input  wire [31:0]     ARADDR,
    input  wire [7:0]      ARLEN,
    input  wire [2:0]      ARSIZE,
    input  wire [1:0]      ARBURST,
    input  wire            ARVALID,
    output wire            ARREADY,
    // ---------------- AXI 讀取資料通道 R ----------------
    output wire [ID_W-1:0] RID,
    output wire [31:0]     RDATA,
    output wire [1:0]      RRESP,
    output wire            RLAST,
    output wire            RVALID,
    input  wire            RREADY,
    // ---------------- Wishbone master 介面（接 wb_dma 的 slave 埠） -------
    output wire            wb_cyc_o,
    output wire            wb_stb_o,
    output wire            wb_we_o,
    output wire [31:0]     wb_adr_o,
    output wire [3:0]      wb_sel_o,
    output wire [31:0]     wb_dat_o,
    input  wire [31:0]     wb_dat_i,
    input  wire            wb_ack_i,
    input  wire            wb_err_i
);

    localparam RESP_OKAY   = 2'b00,
               RESP_SLVERR = 2'b10;
    localparam BURST_FIXED = 2'b00;

    localparam S_IDLE   = 3'd0,
               S_W_DATA = 3'd1,
               S_W_RESP = 3'd2,
               S_R_WB   = 3'd3,
               S_R_DATA = 3'd4;

    reg [2:0]      state, next_state;

    reg [31:0]     addr_q;      // 目前這一拍的位址（burst 時由 wrapper 自己遞增）
    reg [7:0]      cnt_q;       // 讀取 burst 剩餘拍數
    reg [2:0]      size_q;
    reg [1:0]      burst_q;
    reg [ID_W-1:0] id_q;
    reg [1:0]      bresp_q;     // 整個寫入 burst 的累積回應
    reg [31:0]     rdata_q;
    reg [1:0]      rresp_q;

    // 握手成立的條件（VALID 與 READY 同一個時脈邊緣都為 1）
    wire aw_hs   = AWVALID & AWREADY;
    wire ar_hs   = ARVALID & ARREADY;
    wire w_done  = (state == S_W_DATA) & WVALID & (wb_ack_i | wb_err_i);
    wire r_wbdone= (state == S_R_WB) & (wb_ack_i | wb_err_i);

    // 下一拍位址：FIXED 不變，INCR 加上 2^SIZE
    wire [31:0] addr_next = (burst_q == BURST_FIXED) ? addr_q
                                                     : addr_q + (32'd1 << size_q);

    // ---------------- 狀態暫存器 ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) state <= S_IDLE;
        else          state <= next_state;
    end

    // ---------------- 次態邏輯 ----------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:   if (aw_hs)       next_state = S_W_DATA;                 // ①
                      else if (ar_hs)  next_state = S_R_WB;                   // ⑤
            S_W_DATA: if (w_done && WLAST) next_state = S_W_RESP;             // ③（②為自迴圈）
            S_W_RESP: if (BREADY)      next_state = S_IDLE;                   // ④
            S_R_WB:   if (r_wbdone)    next_state = S_R_DATA;                 // ⑥
            S_R_DATA: if (RREADY)      next_state = (cnt_q == 8'd0) ? S_IDLE  // ⑦
                                                                    : S_R_WB; // ⑧
            default:                   next_state = S_IDLE;
        endcase
    end

    // ---------------- 資料路徑 ----------------
    always @(posedge ACLK or negedge ARESETn) begin
        if (!ARESETn) begin
            addr_q  <= 32'd0;  cnt_q   <= 8'd0;  size_q  <= 3'd2;
            burst_q <= 2'b01;  id_q    <= {ID_W{1'b0}};
            bresp_q <= RESP_OKAY;
            rdata_q <= 32'd0;  rresp_q <= RESP_OKAY;
        end else begin
            case (state)
                S_IDLE: begin
                    if (aw_hs) begin                 // 鎖存寫入位址與 ID
                        addr_q  <= AWADDR;  size_q <= AWSIZE;
                        burst_q <= AWBURST; id_q   <= AWID;
                        bresp_q <= RESP_OKAY;
                    end else if (ar_hs) begin        // 鎖存讀取位址、長度與 ID
                        addr_q  <= ARADDR;  size_q <= ARSIZE;
                        burst_q <= ARBURST; id_q   <= ARID;
                        cnt_q   <= ARLEN;
                    end
                end
                S_W_DATA: if (w_done) begin
                    addr_q <= addr_next;             // ② 下一拍位址
                    if (wb_err_i) bresp_q <= RESP_SLVERR;  // 出錯也要把整個 burst 收完
                end
                S_R_WB: if (r_wbdone) begin
                    rdata_q <= wb_dat_i;
                    rresp_q <= wb_err_i ? RESP_SLVERR : RESP_OKAY;
                end
                S_R_DATA: if (RREADY && cnt_q != 8'd0) begin   // ⑧
                    cnt_q  <= cnt_q - 8'd1;
                    addr_q <= addr_next;
                end
                default: ;
            endcase
        end
    end

    // ---------------- AXI 輸出 ----------------
    assign AWREADY = (state == S_IDLE);
    assign ARREADY = (state == S_IDLE) & ~AWVALID;    // 寫入優先
    assign WREADY  = w_done;                          // ACK 回來才吃下這拍
    assign BVALID  = (state == S_W_RESP);
    assign BRESP   = bresp_q;
    assign BID     = id_q;
    assign RVALID  = (state == S_R_DATA);
    assign RDATA   = rdata_q;
    assign RRESP   = rresp_q;
    assign RLAST   = (state == S_R_DATA) & (cnt_q == 8'd0);
    assign RID     = id_q;

    // ---------------- Wishbone 輸出 ----------------
    assign wb_cyc_o = ((state == S_W_DATA) & WVALID) | (state == S_R_WB);
    assign wb_stb_o = wb_cyc_o;
    assign wb_we_o  = (state == S_W_DATA);
    assign wb_adr_o = addr_q;
    assign wb_sel_o = (state == S_W_DATA) ? WSTRB : 4'b1111;
    assign wb_dat_o = WDATA;    // WREADY=0 期間 AXI master 必須保持 WDATA

endmodule
