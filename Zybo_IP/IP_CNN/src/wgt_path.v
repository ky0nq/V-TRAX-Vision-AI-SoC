`timescale 1ns / 1ps

// ============================================================================
// wgt_path : Weight Top
//
//   RAM -> wgt_ld_unit -> wgt_buf -> wgt_patch_gen -> wgt_feeder -> PE (skew)
// ============================================================================
module wgt_path (
    input wire clk,
    input wire rst_n,

    input  wire        i_ld_start,
    input  wire [15:0] i_mem_base,
    input  wire [ 8:0] i_chunk_word_count,   // Number of words to read out of wgt_buf for this chunk 
    input  wire [ 8:0] i_load_chunk_len,     // Number of words to copy from RAM into wgt_buf 
    input  wire        i_buf_half,           // Buffer half
    output wire [15:0] o_mem_rd_addr,
    input  wire [23:0] i_mem_rdata,
    output wire        o_ld_done,
    output wire        o_ld_ready,
    input  wire        i_buf_free,

    // ---- cnn_cntl ----
    input  wire       i_chunk_start,
    input  wire [2:0] i_col_mask,
    output wire       o_chunk_done,
    input  wire       i_feed_en,
    input  wire       i_clear,

    // ---- PE array (skew) ----
    output wire [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready
);

    wire        buf_we;
    wire [ 8:0] buf_waddr;
    wire [23:0] buf_wdata;

    wire        gen_ren;
    wire [ 8:0] gen_raddr;
    wire [23:0] buf_rdata;
    wire        buf_rvalid;
    
    wire [23:0] gen_data;
    wire [ 2:0] gen_keep;
    wire        gen_valid;
    wire        gen_ready;

    wgt_ld_unit WGT_LD_UNIT (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_ld_start         (i_ld_start),
        .i_mem_base         (i_mem_base),
        .i_chunk_word_count (i_load_chunk_len),
        .i_buf_half         (i_buf_half),
        .o_mem_rd_addr      (o_mem_rd_addr),
        .i_mem_rdata        (i_mem_rdata),
        .o_buf_we           (buf_we),
        .o_buf_waddr        (buf_waddr),
        .o_buf_wdata        (buf_wdata),
        .o_ld_done          (o_ld_done),
        .o_ld_ready         (o_ld_ready),
        .i_buf_free         (i_buf_free)
    );

    wgt_buf WGT_BUF (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_we               (buf_we),
        .i_waddr            (buf_waddr),
        .i_wdata            (buf_wdata),
        .i_ren              (gen_ren),
        .i_raddr            (gen_raddr),
        .o_rdata            (buf_rdata),
        .o_rvalid           (buf_rvalid)
    );

    wgt_patch_gen WGT_PATCH_GEN (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_chunk_start      (i_chunk_start),
        .i_chunk_word_count (i_chunk_word_count),
        .i_col_mask         (i_col_mask),
        .i_buf_half         (i_buf_half),
        .o_ren              (gen_ren),
        .o_raddr            (gen_raddr),
        .i_rdata            (buf_rdata),
        .i_rvalid           (buf_rvalid),
        .o_data             (gen_data),
        .o_keep             (gen_keep),
        .o_valid            (gen_valid),
        .i_ready            (gen_ready),
        .o_chunk_done       (o_chunk_done)
    );

    wgt_feeder WGT_FEEDER (
        .clk                (clk),
        .rst_n              (rst_n),
        .i_data             (gen_data),
        .i_keep             (gen_keep),
        .i_valid            (gen_valid),
        .o_ready            (gen_ready),
        .i_feed_en          (i_feed_en),
        .i_clear            (i_clear),
        .o_data             (o_data),
        .o_keep             (o_keep),
        .o_valid            (o_valid),
        .i_ready            (i_ready)
    );          
endmodule


// ============================================================================
// RAM -> wgt_buf copy
// ============================================================================
module wgt_ld_unit (
    input wire clk,
    input wire rst_n,

    input wire        i_ld_start,
    input wire [15:0] i_mem_base,
    input wire [ 8:0] i_chunk_word_count,
    input wire        i_buf_half,

    output wire [15:0] o_mem_rd_addr,
    input  wire [23:0] i_mem_rdata,

    output wire        o_buf_we,
    output wire [ 8:0] o_buf_waddr,
    output wire [23:0] o_buf_wdata,

    output reg  o_ld_done,
    output wire o_ld_ready,
    input  wire i_buf_free
);
    localparam S_IDLE = 1'd0, S_WAIT = 1'd1;

    reg        state;
    reg [15:0] mem_base;
    reg [ 8:0] chunk_len;
    reg [ 8:0] idx;
    reg        buf_half;

    assign o_ld_ready = rst_n && (state == S_IDLE) && i_buf_free;

    wire start_load = i_ld_start && o_ld_ready;
    wire accept_rsp = (state == S_WAIT);
    wire last_word = (idx == chunk_len - 9'd1);

    assign o_mem_rd_addr = (state == S_IDLE) ? i_mem_base
            : mem_base + {7'd0, idx} + 16'd1;

    assign o_buf_we = rst_n && accept_rsp;
    assign o_buf_waddr = {buf_half, idx[7:0]};
    assign o_buf_wdata = i_mem_rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            mem_base  <= 16'd0;
            chunk_len <= 9'd0;
            idx       <= 9'd0;
            buf_half  <= 1'b0;
            o_ld_done <= 1'b0;
        end else begin
            o_ld_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_load) begin
                        mem_base  <= i_mem_base;
                        chunk_len <= i_chunk_word_count;
                        idx       <= 9'd0;
                        buf_half  <= i_buf_half;
                        // length is zero -> Complete immediately
                        if (i_chunk_word_count == 9'd0) o_ld_done <= 1'b1;
                        else state <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (accept_rsp) begin
                        if (last_word) begin
                            o_ld_done <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            idx <= idx + 9'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// ============================================================================
// wgt_buf : 512 x 24bit words = 2 halves x 256 words
// ============================================================================
module wgt_buf (
    input wire clk,
    input wire rst_n,

    input wire        i_we,
    input wire [ 8:0] i_waddr,
    input wire [23:0] i_wdata,

    input wire       i_ren,
    input wire [8:0] i_raddr,

    output reg [23:0] o_rdata,
    output reg        o_rvalid
);
    reg [23:0] mem[0:511];

    always @(posedge clk) begin
        if (!rst_n) begin
            o_rvalid <= 1'b0;
        end else begin
            o_rvalid <= i_ren;
            if (i_we) mem[i_waddr] <= i_wdata;
            if (i_ren) o_rdata <= mem[i_raddr];
        end
    end
endmodule


// ============================================================================
// wgt_patch_gen : Read buffer sequentially and output beats
// ============================================================================
module wgt_patch_gen (
    input wire clk,
    input wire rst_n,

    input wire       i_chunk_start,
    input wire [8:0] i_chunk_word_count,
    input wire [2:0] i_col_mask,
    input wire       i_buf_half,

    output wire        o_ren,
    output wire [ 8:0] o_raddr,
    input  wire [23:0] i_rdata,
    input  wire        i_rvalid,

    output wire [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready,

    output reg o_chunk_done
);
    reg chunk_active;
    reg [8:0] chunk_len_r;
    reg [2:0] col_mask_r;
    reg       rd_half_r;        // Buffer half containing the current chunk
    reg [8:0] rd_idx;           // Index of the next word to read
    reg [1:0] pend_count;       // Number of requested words not yet consumed

    // 2-entry weight data buffer
    reg [23:0] data_buf0, data_buf1;
    reg rd_sel, wr_sel;
    reg [1:0] buf_count;

    wire buf_read = o_valid && i_ready;
    wire rd_req = chunk_active && (rd_idx != chunk_len_r) && ((pend_count < 2'd2) || buf_read);

    assign o_ren   = rd_req;
    assign o_raddr = {rd_half_r, rd_idx[7:0]};

    wire [23:0] out_word = rd_sel ? data_buf1 : data_buf0;
    assign o_valid = chunk_active && (buf_count != 2'd0);
    assign o_keep = col_mask_r;
    assign o_data = {
        col_mask_r[2] ? out_word[23:16] : 8'd0,
        col_mask_r[1] ? out_word[15:8] : 8'd0,
        col_mask_r[0] ? out_word[7:0] : 8'd0
    };

    wire buf_write = chunk_active && i_rvalid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chunk_active <= 1'b0;
            chunk_len_r  <= 9'd0;
            col_mask_r   <= 3'd0;
            rd_half_r    <= 1'b0;
            rd_idx       <= 9'd0;
            pend_count   <= 2'd0;
            rd_sel       <= 1'b0;
            wr_sel       <= 1'b0;
            buf_count    <= 2'd0;
            o_chunk_done <= 1'b0;
        end else begin
            o_chunk_done <= 1'b0;

            if (!chunk_active) begin
                if (i_chunk_start) begin
                    chunk_len_r <= i_chunk_word_count;
                    col_mask_r  <= i_col_mask;
                    rd_half_r   <= i_buf_half;
                    rd_idx      <= 9'd0;
                    pend_count  <= 2'd0;
                    rd_sel      <= 1'b0;
                    wr_sel      <= 1'b0;
                    buf_count   <= 2'd0;
                    if (i_chunk_word_count == 9'd0) o_chunk_done <= 1'b1;
                    else chunk_active <= 1'b1;
                end
            end else begin
                if (rd_req) rd_idx <= rd_idx + 9'd1;

                pend_count <= pend_count + {1'b0, rd_req} - {1'b0, buf_read};

                if (buf_write) begin
                    if (wr_sel) data_buf1 <= i_rdata;
                    else data_buf0 <= i_rdata;
                    wr_sel <= ~wr_sel;
                end

                if (buf_read) rd_sel <= ~rd_sel;

                buf_count <= buf_count + {1'b0, buf_write} - {1'b0, buf_read};

                if (buf_read   && (rd_idx == chunk_len_r) && (pend_count == 2'd1)) begin
                    chunk_active <= 1'b0;
                    o_chunk_done <= 1'b1;
                end
            end
        end
    end

endmodule

// ============================================================================
// wgt_feeder : 1-stage register slice + feed_en 
// Output stage to the skew buffer
// ============================================================================
module wgt_feeder (
    input wire clk,
    input wire rst_n,

    input  wire [23:0] i_data,
    input  wire [ 2:0] i_keep,
    input  wire        i_valid,
    output wire        o_ready,

    input wire i_feed_en,
    input wire i_clear,

    output reg  [23:0] o_data,
    output reg  [ 2:0] o_keep,
    output reg         o_valid,
    input  wire        i_ready
);
    assign o_ready = rst_n && !i_clear && i_feed_en && (!o_valid || i_ready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_data  <= 24'd0;
            o_keep  <= 3'b000;
            o_valid <= 1'b0;
        end else if (i_clear) begin
            o_data  <= 24'd0;
            o_keep  <= 3'b000;
            o_valid <= 1'b0;
        end else begin
            if (o_ready) begin
                o_valid <= i_valid;
                if (i_valid) begin
                    o_data <= i_data;
                    o_keep <= i_keep;
                end
            end else if (o_valid && i_ready) begin
                o_valid <= 1'b0;
            end
        end
    end
endmodule