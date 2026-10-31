`timescale 1ns / 1ps

// ============================================================================
// wgt_path: RAM -> wgt_ld_unit -> wgt_buf -> wgt_patch_gen -> wgt_feeder -> PE
// wgt_buf double-buffered: load one half while the other feeds the PE.
// ============================================================================
module wgt_path (
    input logic clk,
    input logic rst_n,

    input  logic        i_ld_start,
    input  logic [15:0] i_mem_base,
    input  logic [ 8:0] i_chunk_word_count,   // read length 1~256 (pe_cntl)
    input  logic [ 8:0] i_load_chunk_len,     // load length 1~256 (cnn_cntl)
    input  logic        i_buf_half,           // wgt_buf half for this chunk
    output logic [15:0] o_mem_rd_addr,
    input  logic [23:0] i_mem_rdata,
    output logic        o_ld_done,
    output logic        o_ld_ready,
    input  logic        i_buf_free,

    // ---- cnn_cntl ----
    input  logic       i_chunk_start,
    input  logic [2:0] i_col_mask,
    output logic       o_chunk_done,
    input  logic       i_feed_en,
    input  logic       i_clear,

    // ---- PE array (skew) ----
    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready
);

    logic        buf_we;
    logic [ 8:0] buf_waddr;
    logic [23:0] buf_wdata;

    logic        gen_ren;
    logic [ 8:0] gen_raddr;
    logic [23:0] buf_rdata;
    logic        buf_rvalid;

    logic [23:0] gen_data;
    logic [ 2:0] gen_keep;
    logic        gen_valid;
    logic        gen_ready;

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

// wgt_ld_unit: RAM -> wgt_buf copy; waddr = {half latched at i_ld_start, idx}
module wgt_ld_unit (
    input logic clk,
    input logic rst_n,

    input logic        i_ld_start,
    input logic [15:0] i_mem_base,
    input logic [ 8:0] i_chunk_word_count,
    input logic        i_buf_half,

    output logic [15:0] o_mem_rd_addr,
    input  logic [23:0] i_mem_rdata,

    output logic        o_buf_we,
    output logic [ 8:0] o_buf_waddr,
    output logic [23:0] o_buf_wdata,

    output logic o_ld_done,
    output logic o_ld_ready,
    input  logic i_buf_free
);
    typedef enum logic [1:0] { S_IDLE = 2'd0, S_WAIT = 2'd1 } wgt_ld_state_e;

    wgt_ld_state_e state;
    logic [15:0] mem_base;
    logic [ 8:0] chunk_len;
    logic [ 8:0] idx;
    logic        buf_half;

    assign o_ld_ready = rst_n && (state == S_IDLE) && i_buf_free;

    logic start_load;
    assign start_load = i_ld_start && o_ld_ready;
    logic accept_rsp;
    assign accept_rsp = (state == S_WAIT);
    logic last_word;
    assign last_word = (idx == chunk_len - 9'd1);

    assign o_mem_rd_addr = (state == S_IDLE) ? i_mem_base
            : mem_base + {7'd0, idx} + 16'd1;

    assign o_buf_we = rst_n && accept_rsp;
    assign o_buf_waddr = {buf_half, idx[7:0]};
    assign o_buf_wdata = i_mem_rdata;

    always_ff @(posedge clk or negedge rst_n) begin
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

// wgt_buf: 512 x 24bit, two 256-word halves, addr[8] = half; 1-clk read
module wgt_buf (
    input logic clk,
    input logic rst_n,

    input logic        i_we,
    input logic [ 8:0] i_waddr,
    input logic [23:0] i_wdata,

    input logic       i_ren,
    input logic [8:0] i_raddr,

    output logic [23:0] o_rdata,
    output logic        o_rvalid
);
    logic [23:0] mem[0:511];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            o_rvalid <= 1'b0;
        end else begin
            o_rvalid <= i_ren;
            if (i_we) mem[i_waddr] <= i_wdata;
            if (i_ren) o_rdata <= mem[i_raddr];
        end
    end
endmodule

// wgt_patch_gen: sequential wgt_buf reader; raddr = {half latched at i_chunk_start, rd_idx}
module wgt_patch_gen (
    input logic clk,
    input logic rst_n,

    input logic       i_chunk_start,
    input logic [8:0] i_chunk_word_count,
    input logic [2:0] i_col_mask,
    input logic       i_buf_half,

    output logic        o_ren,
    output logic [ 8:0] o_raddr,
    input  logic [23:0] i_rdata,
    input  logic        i_rvalid,

    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready,

    output logic o_chunk_done
);
    logic chunk_active;
    logic [8:0] chunk_len_r;
    logic [2:0] col_mask_r;
    logic       rd_half_r;
    logic [8:0] rd_idx;
    logic [1:0] pend_count;       // words read but not yet sent

    // 2-entry FIFO
    logic [23:0] data_buf0, data_buf1;
    logic rd_sel, wr_sel;
    logic [1:0] buf_count;

    logic buf_read;
    assign buf_read = o_valid && i_ready;
    logic rd_req;
    assign rd_req = chunk_active && (rd_idx != chunk_len_r) && ((pend_count < 2'd2) || buf_read);

    assign o_ren   = rd_req;
    assign o_raddr = {rd_half_r, rd_idx[7:0]};

    logic [23:0] out_word;
    assign out_word = rd_sel ? data_buf1 : data_buf0;
    assign o_valid = chunk_active && (buf_count != 2'd0);
    assign o_keep = col_mask_r;
    assign o_data = {
        col_mask_r[2] ? out_word[23:16] : 8'd0,
        col_mask_r[1] ? out_word[15:8] : 8'd0,
        col_mask_r[0] ? out_word[7:0] : 8'd0
    };

    logic buf_write;
    assign buf_write = chunk_active && i_rvalid;

    always_ff @(posedge clk or negedge rst_n) begin
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

// wgt_feeder: 1-stage register slice gated by feed_en
module wgt_feeder (
    input logic clk,
    input logic rst_n,

    input  logic [23:0] i_data,
    input  logic [ 2:0] i_keep,
    input  logic        i_valid,
    output logic        o_ready,

    input logic i_feed_en,
    input logic i_clear,

    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready
);
    assign o_ready = rst_n && !i_clear && i_feed_en && (!o_valid || i_ready);

    always_ff @(posedge clk or negedge rst_n) begin
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
