// ============================================================================
// AHB Master Wrapper  (Wishbone -> AHB 協定，含 AHB2 仲裁)
// ----------------------------------------------------------------------------
// 用途：wb_dma 的 DMA 引擎用 Wishbone master 發出讀寫，本 wrapper 先向
//       AHB 仲裁器申請匯流排 (HBUSREQ/HGRANT)，再轉成 AHB 單筆傳輸。
//
// FSM（對應作業第 4 步的狀態圖）：
//   IDLE    : 不申請匯流排，等 Wishbone 請求
//   BUS_REQ : HBUSREQ=1，等 HGRANT & HREADY
//   ADDR    : 送出位址相位 (HTRANS=NONSEQ)，等 HREADY
//   DATA    : 資料相位 (HTRANS=IDLE)，等 HREADY 後依 HRESP 決定結果
// ============================================================================
module ahb_master_wrapper (
    input  wire        HCLK,
    input  wire        HRESETn,
    // ---------------- AHB master 介面 ----------------
    output wire        HBUSREQ,
    input  wire        HGRANT,
    input  wire        HREADY,
    input  wire [1:0]  HRESP,
    input  wire [31:0] HRDATA,
    output wire [31:0] HADDR,
    output wire [1:0]  HTRANS,
    output wire        HWRITE,
    output wire [2:0]  HSIZE,
    output wire [2:0]  HBURST,
    output wire [31:0] HWDATA,
    // ---------------- Wishbone slave 介面（接 wb_dma 的 master 埠） -------
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [31:0] wb_adr_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [31:0] wb_dat_i,
    output wire [31:0] wb_dat_o,
    output wire        wb_ack_o,
    output wire        wb_err_o
);

    localparam HTRANS_IDLE   = 2'b00,
               HTRANS_NONSEQ = 2'b10;
    localparam HRESP_OKAY    = 2'b00,
               HRESP_ERROR   = 2'b01,
               HRESP_RETRY   = 2'b10,
               HRESP_SPLIT   = 2'b11;
    localparam HBURST_SINGLE = 3'b000;

    localparam S_IDLE    = 2'd0,
               S_BUS_REQ = 2'd1,
               S_ADDR    = 2'd2,
               S_DATA    = 2'd3;

    reg [1:0] state, next_state;

    wire wb_req = wb_cyc_i & wb_stb_i;

    // ---------------- 狀態暫存器 ----------------
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) state <= S_IDLE;
        else          state <= next_state;
    end

    // ---------------- 次態邏輯 ----------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:    if (wb_req)            next_state = S_BUS_REQ;   // ①
            S_BUS_REQ: if (HGRANT && HREADY)  next_state = S_ADDR;      // ② 取得授權
            S_ADDR:    if (HREADY)            next_state = S_DATA;      // ③ 位址被接受
            S_DATA:    if (HREADY) begin
                           if (HRESP == HRESP_RETRY || HRESP == HRESP_SPLIT)
                                              next_state = S_BUS_REQ;   // ⑤ 重新申請
                           else               next_state = S_IDLE;      // ④ OKAY / ERROR
                       end
            default:                          next_state = S_IDLE;
        endcase
    end

    // 由 Wishbone 的 byte select 推出 HSIZE 與位址低兩位
    reg [2:0] size_c;
    reg [1:0] alow_c;
    always @(*) begin
        case (wb_sel_i)
            4'b0001: begin size_c = 3'b000; alow_c = 2'd0; end
            4'b0010: begin size_c = 3'b000; alow_c = 2'd1; end
            4'b0100: begin size_c = 3'b000; alow_c = 2'd2; end
            4'b1000: begin size_c = 3'b000; alow_c = 2'd3; end
            4'b0011: begin size_c = 3'b001; alow_c = 2'd0; end
            4'b1100: begin size_c = 3'b001; alow_c = 2'd2; end
            default: begin size_c = 3'b010; alow_c = 2'd0; end
        endcase
    end

    // ---------------- AHB 輸出 ----------------
    // Wishbone master 會保持位址與資料直到 ACK，所以這裡直接接線，不需鎖存
    assign HBUSREQ = (state == S_BUS_REQ) || (state == S_ADDR);
    assign HTRANS  = (state == S_ADDR) ? HTRANS_NONSEQ : HTRANS_IDLE;
    assign HADDR   = {wb_adr_i[31:2], alow_c};
    assign HWRITE  = wb_we_i;
    assign HSIZE   = size_c;
    assign HBURST  = HBURST_SINGLE;
    assign HWDATA  = wb_dat_i;

    // ---------------- Wishbone 輸出 ----------------
    assign wb_dat_o = HRDATA;
    assign wb_ack_o = (state == S_DATA) && HREADY && (HRESP == HRESP_OKAY);
    assign wb_err_o = (state == S_DATA) && HREADY && (HRESP == HRESP_ERROR);

endmodule
