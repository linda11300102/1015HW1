// ============================================================================
// AHB Slave Wrapper  (AHB 協定 -> Wishbone)
// ----------------------------------------------------------------------------
// 用途：CPU（AHB master）讀寫 wb_dma 的控制暫存器時，
//       本 wrapper 接收 AHB 傳輸，轉成 Wishbone classic cycle 送給 wb_dma 的
//       Wishbone slave 介面。
//
// FSM（對應作業第 3 步的狀態圖）：
//   IDLE      : HREADYOUT=1，等待有效傳輸 (HSEL & HREADY & HTRANS=NONSEQ/SEQ)
//   WB_ACCESS : 用鎖存的位址發出 Wishbone 傳輸，HREADYOUT=0 插入等待
//   ERR1      : 錯誤回應第 1 拍 (HRESP=ERROR, HREADYOUT=0)
//   ERR2      : 錯誤回應第 2 拍 (HRESP=ERROR, HREADYOUT=1)
// ============================================================================
module ahb_slave_wrapper (
    input  wire        HCLK,
    input  wire        HRESETn,
    // ---------------- AHB slave 介面 ----------------
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire        HWRITE,
    input  wire [1:0]  HTRANS,
    input  wire [2:0]  HSIZE,
    input  wire [31:0] HWDATA,
    input  wire        HREADY,      // 匯流排上的 HREADY（上一筆是否完成）
    output wire        HREADYOUT,   // 本 slave 回給匯流排的 ready
    output wire [1:0]  HRESP,
    output wire [31:0] HRDATA,
    // ---------------- Wishbone master 介面（接 wb_dma 的 slave 埠） -------
    output wire        wb_cyc_o,
    output wire        wb_stb_o,
    output wire        wb_we_o,
    output wire [31:0] wb_adr_o,
    output wire [3:0]  wb_sel_o,
    output wire [31:0] wb_dat_o,
    input  wire [31:0] wb_dat_i,
    input  wire        wb_ack_i,
    input  wire        wb_err_i
);

    // HTRANS / HRESP 編碼
    localparam HTRANS_IDLE   = 2'b00,
               HTRANS_BUSY   = 2'b01,
               HTRANS_NONSEQ = 2'b10,
               HTRANS_SEQ    = 2'b11;
    localparam HRESP_OKAY    = 2'b00,
               HRESP_ERROR   = 2'b01;

    // 狀態編碼
    localparam S_IDLE      = 2'd0,
               S_WB_ACCESS = 2'd1,
               S_ERR1      = 2'd2,
               S_ERR2      = 2'd3;

    reg [1:0]  state, next_state;

    // 位址相位鎖存的控制訊號（AHB 是 pipeline，資料相位時 HADDR 已經換了）
    reg [31:0] addr_q;
    reg        write_q;
    reg [3:0]  sel_q;
    reg [31:0] rdata_q;

    // 「有效傳輸」= 被選中 & 匯流排上一筆已完成 & 傳輸型態是 NONSEQ 或 SEQ
    wire valid_xfer = HSEL & HREADY & HTRANS[1];

    // 依 HSIZE 與 HADDR[1:0] 產生 byte select
    function [3:0] size2sel;
        input [2:0] size;
        input [1:0] a;
        begin
            case (size)
                3'b000:  size2sel = 4'b0001 << a;                 // byte
                3'b001:  size2sel = a[1] ? 4'b1100 : 4'b0011;     // halfword
                default: size2sel = 4'b1111;                      // word
            endcase
        end
    endfunction

    // ---------------- 狀態暫存器 ----------------
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) state <= S_IDLE;
        else          state <= next_state;
    end

    // ---------------- 次態邏輯 ----------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:      if (valid_xfer)    next_state = S_WB_ACCESS;   // ①
            S_WB_ACCESS: if (wb_ack_i)      next_state = S_IDLE;        // ②
                         else if (wb_err_i) next_state = S_ERR1;        // ⑤
            S_ERR1:                         next_state = S_ERR2;        // ⑥
            S_ERR2:      if (valid_xfer)    next_state = S_WB_ACCESS;   // ⑧
                         else               next_state = S_IDLE;        // ⑦
            default:                        next_state = S_IDLE;
        endcase
    end

    // ---------------- 資料路徑：鎖存位址 / 讀回資料 ----------------
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            addr_q  <= 32'd0;
            write_q <= 1'b0;
            sel_q   <= 4'd0;
            rdata_q <= 32'd0;
        end else begin
            // 位址相位：在 IDLE / ERR2（HREADYOUT=1 的狀態）取樣新傳輸
            if ((state == S_IDLE || state == S_ERR2) && valid_xfer) begin
                addr_q  <= HADDR;
                write_q <= HWRITE;
                sel_q   <= size2sel(HSIZE, HADDR[1:0]);
            end
            // Wishbone 回 ACK 時把讀到的資料存起來，下一拍 (IDLE) 送上 HRDATA
            if (state == S_WB_ACCESS && wb_ack_i && !write_q)
                rdata_q <= wb_dat_i;
        end
    end

    // ---------------- 輸出（Moore 型） ----------------
    assign HREADYOUT = (state == S_IDLE) || (state == S_ERR2);
    assign HRESP     = (state == S_ERR1 || state == S_ERR2) ? HRESP_ERROR : HRESP_OKAY;
    assign HRDATA    = rdata_q;

    assign wb_cyc_o  = (state == S_WB_ACCESS);
    assign wb_stb_o  = (state == S_WB_ACCESS);
    assign wb_we_o   = write_q;
    assign wb_adr_o  = addr_q;
    assign wb_sel_o  = sel_q;
    // HREADYOUT=0 期間 AHB master 必須保持 HWDATA，所以可以直接接線
    assign wb_dat_o  = HWDATA;

endmodule
