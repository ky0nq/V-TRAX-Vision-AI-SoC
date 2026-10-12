`timescale 1ns / 1ps
//
// s2mm_axi_writer (S2MM write engine)
//
// [Changes from the previous version] Transfer logic (state machine, burst, address calculation) unchanged
//   1) base_addr[0:2] array port -> split into base_addr0/1/2 (Verilog / IP packaging compatibility)
//   2) Added status outputs
//        busy          : 1 after start (stays 1 since it runs in cyclic mode)
//        frame_done    : 1-clock pulse each time a frame is fully written
//        newest_idx    : index of the buffer just finished (0~2) -> to MM2S's s2mm_newest_idx
//        wr_error      : BRESP error (SLVERR/DECERR) occurred (held until the next start)
//        wr_error_addr : start address of the first burst that got an error
//
// Operation : after start, keeps writing frames in the order base0 -> base1 -> base2 -> base0 ... (cyclic)
//
module s2mm_axi_writer #(
    parameter ID_WIDTH        = 4,
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter FIFO_DEPTH      = 1024,
    parameter BURST_LEN       = 16,
    parameter PIXELS_PER_LINE = 1280,
    parameter FRAME_HEIGHT    = 720,
    parameter PIXEL_BYTES     = 3
)(
    input  wire                              ACLK,
    input  wire                              ARESETN,
    input  wire                              start,
    input  wire [ADDR_WIDTH-1:0]             base_addr0,
    input  wire [ADDR_WIDTH-1:0]             base_addr1,
    input  wire [ADDR_WIDTH-1:0]             base_addr2,

    // Status outputs (added)
    output reg                               busy,
    output reg                               frame_done,
    output reg  [2:0]                        newest_idx,
    output reg                               wr_error,
    output reg  [ADDR_WIDTH-1:0]             wr_error_addr,

    input  wire                              fifo_empty,
    input  wire [$clog2(FIFO_DEPTH+1)-1:0]   fifo_count,
    input  wire [DATA_WIDTH-1:0]             fifo_rd_data,
    output wire                              fifo_rd_en,
    output wire [ID_WIDTH-1:0]               M_AXI_AWID,
    output wire [ADDR_WIDTH-1:0]             M_AXI_AWADDR,
    output wire [3:0]                        M_AXI_AWLEN,
    output wire [2:0]                        M_AXI_AWSIZE,
    output wire [1:0]                        M_AXI_AWBURST,
    output wire [1:0]                        M_AXI_AWLOCK,
    output wire [3:0]                        M_AXI_AWCACHE,
    output wire [2:0]                        M_AXI_AWPROT,
    output wire                              M_AXI_AWVALID,
    input  wire                              M_AXI_AWREADY,
    output wire [ID_WIDTH-1:0]               M_AXI_WID,
    output wire [DATA_WIDTH-1:0]             M_AXI_WDATA,
    output wire [(DATA_WIDTH/8)-1:0]         M_AXI_WSTRB,
    output wire                              M_AXI_WLAST,
    output wire                              M_AXI_WVALID,
    input  wire                              M_AXI_WREADY,
    input  wire [ID_WIDTH-1:0]               M_AXI_BID,
    input  wire [1:0]                        M_AXI_BRESP,
    input  wire                              M_AXI_BVALID,
    output wire                              M_AXI_BREADY
);

    localparam IDLE      = 3'd0;
    localparam WAIT_FIFO = 3'd1;
    localparam AW        = 3'd2;
    localparam PREFETCH  = 3'd3;
    localparam WRITE     = 3'd4;
    localparam BRESP     = 3'd5;

    localparam integer BYTE_WIDTH        = DATA_WIDTH / 8;
    localparam integer BURST_BYTES       = BURST_LEN * BYTE_WIDTH;
    localparam integer LINE_BYTES        = PIXELS_PER_LINE * PIXEL_BYTES;
    localparam integer BURSTS_PER_LINE   = LINE_BYTES / BURST_BYTES;
    localparam integer BEAT_WIDTH        = (BURST_LEN <= 1) ? 1 : $clog2(BURST_LEN);
    localparam integer BURST_COUNT_WIDTH = (BURSTS_PER_LINE <= 1) ? 1 : $clog2(BURSTS_PER_LINE);
    localparam integer LINE_COUNT_WIDTH  = (FRAME_HEIGHT <= 1) ? 1 : $clog2(FRAME_HEIGHT);

    reg [2:0] STATE;
    reg [ADDR_WIDTH-1:0] current_addr;
    reg [BEAT_WIDTH-1:0] beat_count;
    reg [BURST_COUNT_WIDTH-1:0] burst_count;
    reg [LINE_COUNT_WIDTH-1:0] line_count;
    reg [1:0] base_cnt;     // Index of the next buffer to write
    reg [1:0] wr_idx;       // Index of the buffer currently being written (added)

    // Buffer address pointed to by base_cnt (selector instead of an array)
    wire [ADDR_WIDTH-1:0] base_sel = (base_cnt == 2'd0) ? base_addr0 :
                                     (base_cnt == 2'd1) ? base_addr1 :
                                                          base_addr2;

    wire aw_handshake;
    wire w_handshake;
    wire b_handshake;

    assign aw_handshake = M_AXI_AWVALID && M_AXI_AWREADY;
    assign w_handshake  = M_AXI_WVALID && M_AXI_WREADY;
    assign b_handshake  = M_AXI_BVALID && M_AXI_BREADY;

    assign M_AXI_AWID    = {ID_WIDTH{1'b0}};
    assign M_AXI_AWADDR  = current_addr;
    assign M_AXI_AWLEN   = BURST_LEN - 1;
    assign M_AXI_AWSIZE  = $clog2(BYTE_WIDTH);
    assign M_AXI_AWBURST = 2'b01;
    assign M_AXI_AWLOCK  = 2'b00;
    assign M_AXI_AWCACHE = 4'b0011;
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWVALID = (STATE == AW);

    assign M_AXI_WID    = {ID_WIDTH{1'b0}};
    assign M_AXI_WDATA  = fifo_rd_data;
    assign M_AXI_WSTRB  = {BYTE_WIDTH{1'b1}};
    assign M_AXI_WVALID = (STATE == WRITE);
    assign M_AXI_WLAST  = (STATE == WRITE) && (beat_count == BURST_LEN-1);

    assign M_AXI_BREADY = (STATE == BRESP);

    assign fifo_rd_en =
        ((STATE == PREFETCH) && !fifo_empty) ||
        ((STATE == WRITE) && w_handshake && (beat_count != BURST_LEN-1));

    always @(posedge ACLK) begin
        if (!ARESETN) begin
            STATE         <= IDLE;
            current_addr  <= 0;
            beat_count    <= 0;
            burst_count   <= 0;
            line_count    <= 0;
            base_cnt      <= 0;
            wr_idx        <= 0;
            busy          <= 1'b0;
            frame_done    <= 1'b0;
            newest_idx    <= 3'd0;
            wr_error      <= 1'b0;
            wr_error_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            frame_done <= 1'b0;   // 1-clock pulse

            case (STATE)
                IDLE : begin
                    beat_count <= 0;
                    if (start) begin
                        current_addr  <= base_sel;
                        wr_idx        <= base_cnt;
                        base_cnt      <= (base_cnt == 2'd2) ? 2'd0 : base_cnt + 1'b1;
                        beat_count    <= 0;
                        burst_count   <= 0;
                        line_count    <= 0;
                        busy          <= 1'b1;
                        wr_error      <= 1'b0;
                        wr_error_addr <= {ADDR_WIDTH{1'b0}};
                        STATE         <= WAIT_FIFO;
                    end
                end

                WAIT_FIFO : begin
                    if (fifo_count >= BURST_LEN) STATE <= AW;
                end

                AW : begin
                    if (aw_handshake) begin
                        beat_count <= 0;
                        STATE      <= PREFETCH;
                    end
                end

                PREFETCH : begin
                    if (!fifo_empty) STATE <= WRITE;
                end

                WRITE : begin
                    if (w_handshake) begin
                        if (beat_count == BURST_LEN-1) begin
                            beat_count <= 0;
                            STATE      <= BRESP;
                        end else begin
                            beat_count <= beat_count + 1'b1;
                        end
                    end
                end

                BRESP : begin
                    if (b_handshake) begin
                        // On an error response, record only the first one (current_addr = start address of the burst just sent)
                        if (M_AXI_BRESP[1] && !wr_error) begin
                            wr_error      <= 1'b1;
                            wr_error_addr <= current_addr;
                        end

                        if (burst_count == BURSTS_PER_LINE-1) begin
                            burst_count <= 0;
                            if (line_count == FRAME_HEIGHT-1) begin
                                // ---- Frame complete ----
                                line_count   <= 0;
                                frame_done   <= 1'b1;
                                newest_idx   <= {1'b0, wr_idx};      // Buffer just finished
                                current_addr <= base_sel;            // Move to the next buffer
                                wr_idx       <= base_cnt;
                                base_cnt     <= (base_cnt == 2'd2) ? 2'd0 : base_cnt + 1'b1;
                            end else begin
                                line_count   <= line_count + 1'b1;
                                current_addr <= current_addr + BURST_BYTES;
                            end
                        end else begin
                            burst_count  <= burst_count + 1'b1;
                            current_addr <= current_addr + BURST_BYTES;
                        end

                        STATE <= WAIT_FIFO;
                    end
                end

                default : begin
                    STATE <= IDLE;
                end
            endcase
        end
    end

    wire _unused_bid = |M_AXI_BID;

endmodule
