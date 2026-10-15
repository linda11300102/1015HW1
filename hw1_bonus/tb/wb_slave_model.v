// ============================================================================
// Wishbone slave 行為模型：模擬 wb_dma 的控制暫存器（slave 埠）
// ----------------------------------------------------------------------------
// - 64 個 32-bit 暫存器，位址 0x000 ~ 0x0FF
// - 位址 >= 0x100 視為不存在的暫存器，回 ERR
// - 參數 WAIT：收到 STB 後要等幾拍才回 ACK（模擬存取延遲）
// ============================================================================
module wb_slave_model #(
    parameter WAIT = 1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [31:0] wb_adr_i,
    input  wire [3:0]  wb_sel_i,
    input  wire [31:0] wb_dat_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,
    output reg         wb_err_o
);
    reg [31:0] regs [0:63];
    reg [3:0]  cnt;
    integer i;

    wire       hit = (wb_adr_i < 32'h100);
    wire [5:0] idx = wb_adr_i[7:2];

    always @(posedge clk) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_err_o <= 1'b0;
            wb_dat_o <= 32'd0;
            cnt      <= 4'd0;
            for (i = 0; i < 64; i = i + 1) regs[i] <= 32'd0;
        end else begin
            wb_ack_o <= 1'b0;
            wb_err_o <= 1'b0;
            if (wb_cyc_i && wb_stb_i && !wb_ack_o && !wb_err_o) begin
                if (cnt == WAIT) begin
                    cnt <= 4'd0;
                    if (hit) begin
                        wb_ack_o <= 1'b1;
                        if (wb_we_i) begin
                            if (wb_sel_i[0]) regs[idx][7:0]   <= wb_dat_i[7:0];
                            if (wb_sel_i[1]) regs[idx][15:8]  <= wb_dat_i[15:8];
                            if (wb_sel_i[2]) regs[idx][23:16] <= wb_dat_i[23:16];
                            if (wb_sel_i[3]) regs[idx][31:24] <= wb_dat_i[31:24];
                        end else begin
                            wb_dat_o <= regs[idx];
                        end
                    end else begin
                        wb_err_o <= 1'b1;
                    end
                end else begin
                    cnt <= cnt + 4'd1;
                end
            end else begin
                cnt <= 4'd0;
            end
        end
    end
endmodule
