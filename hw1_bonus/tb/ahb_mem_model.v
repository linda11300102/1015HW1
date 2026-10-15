// ============================================================================
// AHB slave 行為模型：模擬記憶體控制器
// ----------------------------------------------------------------------------
// - 256 words 記憶體（位址取 [9:2]）
// - 參數 WAIT：每筆資料相位插入的等待拍數
// - 位址 0x8000_0000 以上：回 ERROR（兩拍回應）
// - 位址 0x4000_0000 ~ 0x7FFF_FFFF：第一次存取回 RETRY（兩拍回應），
//   master 重送後才回 OKAY，用來測試 master wrapper 的 RETRY 處理
// ============================================================================
module ahb_mem_model #(
    parameter WAIT = 1
)(
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire        HSEL,
    input  wire [31:0] HADDR,
    input  wire        HWRITE,
    input  wire [1:0]  HTRANS,
    input  wire [2:0]  HSIZE,
    input  wire [31:0] HWDATA,
    input  wire        HREADY,
    output wire        HREADYOUT,
    output wire [1:0]  HRESP,
    output wire [31:0] HRDATA
);
    localparam OKAY = 2'b00, ERROR = 2'b01, RETRY = 2'b10;
    localparam ST_OK = 2'd0, ST_WAIT = 2'd1, ST_R1 = 2'd2, ST_R2 = 2'd3;

    reg [31:0] mem [0:255];
    reg [1:0]  st;
    reg [3:0]  cnt;
    reg        dp_active, dp_write;
    reg [31:0] dp_addr;
    reg [1:0]  kind;           // 這筆傳輸最後要回的 HRESP
    reg        retry_armed;    // 1 = 下一次存取 RETRY 區會被 RETRY
    integer i;

    wire new_xfer = HSEL & HREADY & HTRANS[1];

    function [1:0] classify;
        input [31:0] a;
        begin
            if (a[31])                      classify = ERROR;
            else if (a[30] && retry_armed)  classify = RETRY;
            else                            classify = OKAY;
        end
    endfunction

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            st <= ST_OK; cnt <= 0; dp_active <= 0; dp_write <= 0;
            dp_addr <= 0; kind <= OKAY; retry_armed <= 1'b1;
            for (i = 0; i < 256; i = i + 1) mem[i] <= 32'h0;
        end else begin
            // 資料相位在 HREADYOUT=1 的狀態（ST_OK / ST_R2）完成
            if ((st == ST_OK) && dp_active && dp_write && kind == OKAY)
                mem[dp_addr[9:2]] <= HWDATA;

            case (st)
                ST_OK, ST_R2: begin
                    if (new_xfer) begin
                        dp_active <= 1'b1;
                        dp_write  <= HWRITE;
                        dp_addr   <= HADDR;
                        kind      <= classify(HADDR);
                        if (classify(HADDR) == RETRY) retry_armed <= 1'b0;
                        else if (HADDR[30])           retry_armed <= 1'b1;
                        if (classify(HADDR) != OKAY)  st <= ST_R1;
                        else if (WAIT != 0) begin st <= ST_WAIT; cnt <= WAIT - 1; end
                        else                          st <= ST_OK;
                    end else begin
                        dp_active <= 1'b0;
                        st        <= ST_OK;
                    end
                end
                ST_WAIT: begin
                    if (cnt == 0) st <= ST_OK;
                    else          cnt <= cnt - 1;
                end
                ST_R1: st <= ST_R2;
                default: st <= ST_OK;
            endcase
        end
    end

    assign HREADYOUT = (st == ST_OK) || (st == ST_R2);
    assign HRESP     = (st == ST_R1 || st == ST_R2) ? kind : OKAY;
    assign HRDATA    = mem[dp_addr[9:2]];
endmodule
