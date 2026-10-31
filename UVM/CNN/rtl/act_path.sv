`timescale 1ns / 1ps

// ============================================================================
// act_path: RAM -> act_ld_unit -> input_buf -> act_patch_gen (conv) / fc_gen (FC)
//           -> MUX -> act_feeder -> PE. out_path writes results back into input_buf.
// ============================================================================
module act_path (
    input logic clk,
    input logic rst_n,

    // ---- RAM -> input_buf load ----
    input  logic        i_ld_start,
    input  logic [31:0] i_ram_base,
    input  logic [12:0] i_ld_word_count,
    output logic [11:0] o_ram_rd_addr,
    input  logic [23:0] i_ram_rdata,
    output logic        o_ld_done,

    // ---- cnn_cntl ----
    input logic        i_fc_mode,
    input logic        i_pg_tile_start,
    input logic        i_fc_tile_start,
    input logic [13:0] i_src_base,
    input logic [13:0] i_pos_base,
    input logic [ 5:0] i_in_c,
    input logic [ 6:0] i_in_h,
    input logic [ 6:0] i_in_w,
    input logic [ 1:0] i_stride,
    input logic        i_pad_en,
    input logic [12:0] i_k_total,
    input logic [ 2:0] i_row_mask,
    input logic [12:0] i_fc_in_count,
    input logic        i_feed_en,
    input logic        i_clear,

    // ---- PE array ----
    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready,

    // ---- result_buf ----
    input logic        i_wr_en,
    input logic [13:0] i_wr_addr,
    input logic [23:0] i_wr_data,
    input logic [ 2:0] i_wr_be
);

    logic        ibuf_we;
    logic [13:0] ibuf_waddr;
    logic [23:0] ibuf_wdata;
    logic [ 2:0] ibuf_wbe;

    // input_buf read arbitration
    logic pg_rd_en, fc_rd_en;
    logic [13:0] pg_rd_addr, fc_rd_addr;
    logic [23:0] ibuf_rdata;
    logic        ibuf_rvalid;

    logic        ibuf_rd_en;
    assign ibuf_rd_en = i_fc_mode ? fc_rd_en : pg_rd_en;
    logic [13:0] ibuf_rd_addr;
    assign ibuf_rd_addr = i_fc_mode ? fc_rd_addr : pg_rd_addr;

    // generator -> MUX -> feeder
    logic [23:0] pg_data, fc_data, mux_data;
    logic [2:0] pg_keep, fc_keep, mux_keep;
    logic pg_valid, fc_valid, mux_valid;
    logic pg_ready, fc_ready, mux_ready;

    act_ld_unit ACT_LD_UNIT (
        .clk            (clk),
        .rst_n          (rst_n),
        .i_ld_start     (i_ld_start),
        .i_ram_base     (i_ram_base),
        .i_ld_word_count(i_ld_word_count),
        .o_ram_rd_addr  (o_ram_rd_addr),
        .i_ram_rdata    (i_ram_rdata),
        .o_ibuf_we      (ibuf_we),
        .o_ibuf_waddr   (ibuf_waddr),
        .o_ibuf_wdata   (ibuf_wdata),
        .o_ibuf_wbe     (ibuf_wbe),
        .o_ld_done      (o_ld_done)
    );

    input_buf INPUT_BUF (
        .clk       (clk),
        .rst_n     (rst_n),
        .i_wr_en   (ibuf_we | i_wr_en),
        .i_wr_addr (i_wr_en ? i_wr_addr : ibuf_waddr),
        .i_wr_data (i_wr_en ? i_wr_data : ibuf_wdata),
        .i_wr_be   (i_wr_en ? i_wr_be : ibuf_wbe),
        .i_rd_en   (ibuf_rd_en),
        .i_rd_addr (ibuf_rd_addr),
        .o_rd_data (ibuf_rdata),
        .o_rd_valid(ibuf_rvalid)
    );

    act_patch_gen ACT_PATCH_GEN (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_tile_start(i_pg_tile_start && !i_fc_mode),
        .i_src_base  (i_src_base),
        .i_pos_base  (i_pos_base),
        .i_in_c      (i_in_c),
        .i_in_h      (i_in_h),
        .i_in_w      (i_in_w),
        .i_stride    (i_stride),
        .i_pad_en    (i_pad_en),
        .i_k_total   (i_k_total),
        .i_row_mask  (i_row_mask),
        .o_rd_en     (pg_rd_en),
        .o_rd_addr   (pg_rd_addr),
        .i_rd_data   (ibuf_rdata),
        .i_rd_valid  (ibuf_rvalid && !i_fc_mode),
        .o_data      (pg_data),
        .o_keep      (pg_keep),
        .o_valid     (pg_valid),
        .i_ready     (pg_ready)
    );

    fc_gen FC_GEN (
        .clk          (clk),
        .rst_n        (rst_n),
        .i_tile_start (i_fc_tile_start && i_fc_mode),
        .i_src_base   (i_src_base),
        .i_fc_in_count(i_fc_in_count),
        .o_rd_en      (fc_rd_en),
        .o_rd_addr    (fc_rd_addr),
        .i_rd_data    (ibuf_rdata),
        .i_rd_valid   (ibuf_rvalid && i_fc_mode),
        .o_data       (fc_data),
        .o_keep       (fc_keep),
        .o_valid      (fc_valid),
        .i_ready      (fc_ready)
    );

    MUX MUX (
        .i_fc_mode (i_fc_mode),
        .i_pg_data (pg_data),
        .i_pg_keep (pg_keep),
        .i_pg_valid(pg_valid),
        .o_pg_ready(pg_ready),
        .i_fc_data (fc_data),
        .i_fc_keep (fc_keep),
        .i_fc_valid(fc_valid),
        .o_fc_ready(fc_ready),
        .o_data    (mux_data),
        .o_keep    (mux_keep),
        .o_valid   (mux_valid),
        .i_ready   (mux_ready)
    );

    act_feeder ACT_FEEDER (
        .clk      (clk),
        .rst_n    (rst_n),
        .i_data   (mux_data),
        .i_keep   (mux_keep),
        .i_valid  (mux_valid),
        .o_ready  (mux_ready),
        .i_feed_en(i_feed_en),
        .i_clear  (i_clear),
        .o_data   (o_data),
        .o_keep   (o_keep),
        .o_valid  (o_valid),
        .i_ready  (i_ready)
    );

endmodule

// act_ld_unit: image RAM -> input_buf copy (RAM data 1 clk after addr)
module act_ld_unit (
    input logic clk,
    input logic rst_n,

    input logic        i_ld_start,
    input logic [31:0] i_ram_base,
    input logic [12:0] i_ld_word_count,

    output logic [11:0] o_ram_rd_addr,
    input  logic [23:0] i_ram_rdata,

    output logic        o_ibuf_we,
    output logic [13:0] o_ibuf_waddr,
    output logic [23:0] o_ibuf_wdata,
    output logic [ 2:0] o_ibuf_wbe,

    output logic o_ld_done
);
    typedef enum logic {S_IDLE = 1'b0, S_WAIT = 1'b1} act_ld_state_e;

    act_ld_state_e state;
    logic [31:0] ram_base;
    logic [12:0] word_count;
    logic [12:0] word_index;

    logic start_rd;
    assign start_rd = (state == S_IDLE) && i_ld_start && (i_ld_word_count != 13'd0);
    logic accept_rsp;
    assign accept_rsp = (state == S_WAIT);
    logic last_word;
    assign last_word = (word_index == word_count - 13'd1);

    // Pipelined: next word's addr issued while current word returns
    logic [31:0] ram_addr_full;
    assign ram_addr_full = (state == S_IDLE) ? i_ram_base : (ram_base
                + {19'd0, word_index} + 32'd1);

    // Requires ram_base + word_count <= 4096
    assign o_ram_rd_addr = ram_addr_full[11:0];

    assign o_ibuf_we    = rst_n && accept_rsp;
    assign o_ibuf_waddr = {1'b0, word_index};
    assign o_ibuf_wdata = i_ram_rdata;
    assign o_ibuf_wbe   = 3'b111;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ram_base   <= 32'd0;
            word_count <= 13'd0;
            word_index <= 13'd0;
            o_ld_done  <= 1'b0;
        end else begin
            o_ld_done <= 0;

            case (state)
                S_IDLE: begin
                    if (i_ld_start) begin
                        ram_base   <= i_ram_base;
                        word_count <= i_ld_word_count;
                        word_index <= 13'd0;

                        if (i_ld_word_count == 0) o_ld_done <= 1;
                        else state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    if (accept_rsp) begin
                        if (last_word) begin
                            o_ld_done <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            word_index <= word_index + 1;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// input_buf: 16K x 24bit, per-byte write enable, 1-clk read
module input_buf (
    input logic        clk,
    input logic        rst_n,
    input logic        i_wr_en,
    input logic [13:0] i_wr_addr,
    input logic [23:0] i_wr_data,
    input logic [ 2:0] i_wr_be,

    input logic        i_rd_en,
    input logic [13:0] i_rd_addr,

    output logic [23:0] o_rd_data,
    output logic        o_rd_valid
);
    logic [23:0] mem[0:16383];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            o_rd_valid <= 1'b0;
        end else begin
            o_rd_valid <= i_rd_en;
            if (i_wr_en) begin
                if (i_wr_be[0]) mem[i_wr_addr][7:0] <= i_wr_data[7:0];
                if (i_wr_be[1]) mem[i_wr_addr][15:8] <= i_wr_data[15:8];
                if (i_wr_be[2]) mem[i_wr_addr][23:16] <= i_wr_data[23:16];
            end

            if (i_rd_en) o_rd_data <= mem[i_rd_addr];
        end
    end
endmodule

// act_patch_gen: 3x3 conv patches for 3 PE lanes; caches 4x4 input windows (4 patches each)
module act_patch_gen (
    input logic clk,
    input logic rst_n,

    input logic        i_tile_start,
    input logic [13:0] i_src_base,
    input logic [13:0] i_pos_base,
    input logic [ 5:0] i_in_c,
    input logic [ 6:0] i_in_h,
    input logic [ 6:0] i_in_w,
    input logic [ 1:0] i_stride,
    input logic        i_pad_en,
    input logic [12:0] i_k_total,
    input logic [ 2:0] i_row_mask,

    output logic        o_rd_en,
    output logic [13:0] o_rd_addr,
    input  logic [23:0] i_rd_data,
    input  logic        i_rd_valid,

    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready
);

    typedef enum logic [2:0] {
        S_IDLE     = 3'd0,
        S_SELECT   = 3'd1,
        S_CAP_INIT = 3'd2,
        S_CAP_REQ  = 3'd3,
        S_CAP_WAIT = 3'd4,
        S_SEND     = 3'd5
    } act_pg_state_e;

    act_pg_state_e state;

    // ---- tile / layer config ----
    logic [13:0] src_base;
    logic [5:0] in_c;
    logic [6:0] in_h;
    logic [6:0] in_w;
    logic pad_en;
    logic [12:0] k_total;
    logic [2:0] row_mask;
    logic words2;  // 1: Cin=6 (2 words/pixel), 0: Cin=3
    logic [5:0] wpr;  // windows per row = out_w/2
    logic [2:0] wpr_sh;    // log2(wpr), wpr is pow2
    logic [5:0] wpr_mask;
    logic [2:0] in_w_sh;   // log2(in_w), in_w is pow2
    logic [13:0] base_patch;
    logic [1:0] patch_lane;

    logic signed [15:0] in_w_s16;
    assign in_w_s16 = {9'd0, in_w};

    // log2 of pow2 1..64 (leading-1 position); shifts replace division for timing
    function automatic logic [2:0] f_log2_7(input logic [6:0] v);
        begin
            casez (v)
                7'b1??????: f_log2_7 = 3'd6;
                7'b01?????: f_log2_7 = 3'd5;
                7'b001????: f_log2_7 = 3'd4;
                7'b0001???: f_log2_7 = 3'd3;
                7'b00001??: f_log2_7 = 3'd2;
                7'b000001?: f_log2_7 = 3'd1;
                default:    f_log2_7 = 3'd0;
            endcase
        end
    endfunction

    // ---- window cache: 2 banks x 32 words ----
    logic [23:0] window_mem[0:63];
    logic [1:0] win_valid;
    logic [11:0] win_tag0, win_tag1;

    logic [13:0] cur_patch;
    assign cur_patch = base_patch + {12'd0, patch_lane};
    logic [11:0] cur_win;
    assign cur_win = cur_patch[13:2];
    logic cur_bank;
    assign cur_bank = cur_win[0];
    logic [11:0] cur_tag;
    assign cur_tag = cur_bank ? win_tag1 : win_tag0;
    logic cur_hit;
    assign cur_hit = win_valid[cur_bank] && (cur_tag == cur_win);

    // Window position in the output grid (shift/mask, no divider)
    logic [5:0] win_x;
    assign win_x = cur_win[5:0] & wpr_mask;
    logic [5:0] win_y;
    assign win_y = cur_win >> wpr_sh;

    // Top-left of the 4x4 input region
    logic signed [8:0] org_x;
    assign org_x = $signed(
        {2'b00, win_x, 1'b0}
    ) - (pad_en ? 9'sd1 : 9'sd0);

    logic signed [8:0] org_y;
    assign org_y = $signed(
        {2'b00, win_y, 1'b0}
    ) - (pad_en ? 9'sd1 : 9'sd0);

    // pixel index = y*in_w + x
    logic signed [15:0] org_L;
    assign org_L = ($signed({{7{org_y[8]}}, org_y}) <<< in_w_sh) + org_x;

    // ---- capture counter ----
    logic signed [8:0] cap_x, cap_y;
    logic signed [15:0] cap_lin;
    logic [1:0] cap_cx, cap_cy;
    logic cap_grp;
    // word addr within the 4x4 window
    logic [4:0] cap_word;
    assign cap_word = words2 ? {cap_cy, cap_cx, cap_grp} : {1'b0, cap_cy, cap_cx};

    logic signed [9:0] in_w_s10;
    assign in_w_s10 = {3'b000, in_w};
    logic signed [9:0] in_h_s10;
    assign in_h_s10 = {3'b000, in_h};
    logic cap_in_range;
    assign cap_in_range = (cap_x >= 0) && (cap_x < in_w_s10) &&
                        (cap_y >= 0) && (cap_y < in_h_s10);
    logic cap_last;
    assign cap_last = (cap_cx == 2'd3) && (cap_cy == 2'd3) && (cap_grp == words2);

    logic [15:0] cap_lin_sh;
    assign cap_lin_sh = words2 ? {cap_lin[14:0], 1'b0} : cap_lin;
    logic [15:0] cap_addr_full;
    assign cap_addr_full = {2'b00, src_base} + cap_lin_sh + {15'd0, cap_grp};

    // ---- send counter ----
    logic [12:0] send_k;
    logic [1:0] send_kx, send_ky;
    logic  [1:0] send_byte;
    logic        send_grp;     // 0: C0-C2, 1: C3-C5
    logic [5:0] send_ch;
    assign send_ch = (send_grp ? 6'd3 : 6'd0) + {4'd0, send_byte};

    assign o_valid = rst_n && (state == S_SEND) && (row_mask != 3'b000);
    assign o_keep  = row_mask;

    logic [23:0] lane_data;
    logic [13:0] lane_patch;
    logic [3:0] pix;
    logic [5:0] widx;

    always_comb begin
        for (int lane = 0; lane < 3; lane = lane + 1) begin
            lane_patch = base_patch + lane;

            // pixel in 4x4 window: patch start 0/1/4/5 + kernel offset
            pix = {1'b0, lane_patch[1], 1'b0, lane_patch[0]}
                + {send_ky, 2'b00}
                + {2'b00, send_kx};

            // patch bit 2 = bank
            widx = words2
                ? {lane_patch[2], pix, send_grp}
                : {lane_patch[2], 1'b0, pix};

            lane_data[8*lane +: 8] =
                (state == S_SEND && row_mask[lane])
                ? window_mem[widx][8*send_byte +: 8]
                : 8'd0;
        end
    end

    assign o_data = lane_data;

    // capture advance, shared by S_CAP_REQ / S_CAP_WAIT
    task cap_advance();
        begin
            if (cap_last) begin
                if (cur_bank) win_tag1 <= cur_win;
                else win_tag0 <= cur_win;
                win_valid[cur_bank] <= 1'b1;
                state <= S_SELECT;
            end else begin
                state <= S_CAP_REQ;
                if (words2 && !cap_grp) begin
                    cap_grp <= 1'b1;
                end else begin
                    cap_grp <= 1'b0;
                    if (cap_cx == 2'd3) begin
                        cap_cx  <= 2'd0;
                        cap_cy  <= cap_cy + 2'd1;
                        cap_x   <= org_x;
                        cap_y   <= cap_y + 9'sd1;
                        cap_lin <= cap_lin + in_w_s16 - 16'sd3;   // x=3 -> next row x=0
                    end else begin
                        cap_cx  <= cap_cx + 2'd1;
                        cap_x   <= cap_x + 9'sd1;
                        cap_lin <= cap_lin + 16'sd1;
                    end
                end
            end
        end
    endtask

    logic [6:0] out_w_in;
    assign out_w_in = i_pad_en ? i_in_w : (i_in_w - 7'd2);
    logic [5:0] wpr_in;
    assign wpr_in   = (out_w_in[6:1] == 6'd0) ? 6'd1 : out_w_in[6:1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            src_base   <= 14'd0;
            in_c       <= 6'd3;
            in_h       <= 7'd0;
            in_w       <= 7'd0;
            pad_en     <= 1'b0;
            k_total    <= 13'd0;
            row_mask   <= 3'b000;
            words2     <= 1'b0;
            wpr        <= 6'd1;
            wpr_sh     <= 3'd0;
            wpr_mask   <= 6'd0;
            in_w_sh    <= 3'd0;
            base_patch <= 14'd0;
            patch_lane <= 2'd0;
            win_valid  <= 2'b00;
            win_tag0   <= 12'd0;
            win_tag1   <= 12'd0;
            o_rd_en    <= 1'b0;
            o_rd_addr  <= 14'd0;
            send_k     <= 13'd0;
            send_kx    <= 2'd0;
            send_ky    <= 2'd0;
            send_byte  <= 2'd0;
            send_grp   <= 1'b0;
        end else begin
            o_rd_en <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (i_tile_start) begin
                        base_patch <= i_pos_base;
                        patch_lane <= 2'd0;
                        row_mask <= i_row_mask;

                        src_base <= i_src_base;
                        in_c <= i_in_c;
                        in_h <= i_in_h;
                        in_w <= i_in_w;
                        pad_en <= i_pad_en;
                        k_total <= i_k_total;
                        words2 <= (i_in_c > 6'd3);
                        wpr <= wpr_in;
                        wpr_sh   <= f_log2_7({1'b0, wpr_in});
                        wpr_mask <= wpr_in - 6'd1;
                        in_w_sh  <= f_log2_7(i_in_w);

                        if ((i_pos_base == 14'd0) ||
                            (i_src_base != src_base) ||
                            (i_in_c     != in_c)     ||
                            (i_in_h     != in_h)     ||
                            (i_in_w     != in_w)     ||
                            (i_pad_en   != pad_en)) begin
                            win_valid <= 2'b00;
                        end

                        state <= S_SELECT;
                    end
                end

                // Ensure each active lane's window is cached
                S_SELECT: begin
                    if (patch_lane == 2'd3) begin
                        send_k    <= 13'd0;
                        send_kx   <= 2'd0;
                        send_ky   <= 2'd0;
                        send_byte <= 2'd0;
                        send_grp  <= 1'b0;
                        state     <= (row_mask == 3'b000) ? S_IDLE : S_SEND;
                    end else if (!row_mask[patch_lane]) begin
                        patch_lane <= patch_lane + 2'd1;
                    end else if (cur_hit) begin
                        patch_lane <= patch_lane + 2'd1;
                    end else begin
                        win_valid[cur_bank] <= 1'b0;
                        state <= S_CAP_INIT;
                    end
                end

                S_CAP_INIT: begin
                    cap_x   <= org_x;
                    cap_y   <= org_y;
                    cap_lin <= org_L;
                    cap_cx  <= 2'd0;
                    cap_cy  <= 2'd0;
                    cap_grp <= 1'b0;
                    state   <= S_CAP_REQ;
                end

                // out-of-range (padding) pixels stored as 0
                S_CAP_REQ: begin
                    if (cap_in_range) begin
                        o_rd_en   <= 1'b1;
                        o_rd_addr <= cap_addr_full[13:0];
                        state     <= S_CAP_WAIT;
                    end else begin
                        window_mem[{cur_bank, cap_word}] <= 24'd0;
                        cap_advance;
                    end
                end

                S_CAP_WAIT: begin
                    if (i_rd_valid) begin
                        window_mem[{cur_bank, cap_word}] <= i_rd_data;
                        cap_advance;
                    end
                end

                S_SEND: begin
                    if (o_valid && i_ready) begin
                        if (send_k == k_total - 13'd1) begin
                            state <= S_IDLE;
                        end else begin
                            send_k <= send_k + 13'd1;
                            if (send_ch == in_c - 6'd1) begin
                                send_byte <= 2'd0;
                                send_grp  <= 1'b0;
                                if (send_kx == 2'd2) begin
                                    send_kx <= 2'd0;
                                    send_ky <= send_ky + 2'd1;
                                end else begin
                                    send_kx <= send_kx + 2'd1;
                                end
                            end else begin
                                if (send_byte == 2'd2) begin
                                    send_byte <= 2'd0;
                                    send_grp  <= 1'b1;
                                end else begin
                                    send_byte <= send_byte + 2'd1;
                                end
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// fc_gen: streams FC inputs one byte per beat on lane 0, 1-word cache
module fc_gen (
    input logic clk,
    input logic rst_n,

    input logic        i_tile_start,
    input logic [13:0] i_src_base,
    input logic [12:0] i_fc_in_count,

    output logic        o_rd_en,
    output logic [13:0] o_rd_addr,
    input  logic [23:0] i_rd_data,
    input  logic        i_rd_valid,

    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready
);
    // Conv output 32x32x4 -> 4096 FC0 inputs
    localparam integer FC0_CHANNELS = 4;
    localparam integer FC0_INPUT_COUNT = 32 * 32 * FC0_CHANNELS;

    typedef enum logic [1:0] {S_IDLE = 2'd0, S_GET = 2'd1, S_WAIT = 2'd2, S_SEND = 2'd3} fc_gen_state_e;

    fc_gen_state_e state;

    logic [13:0] base_addr;
    logic [12:0] input_count;
    logic [12:0] k;

    logic        cached_valid;
    logic [13:0] cached_addr;
    logic [23:0] cached_word;

    logic [13:0] wanted_addr;

    logic [12:0] word_offset;
    logic [ 1:0] byte_lane;
    logic [12:0] k_word;      // k / 3, counter (no divider)
    logic [ 1:0] k_lane;      // k % 3

    logic        cache_hit;
    assign cache_hit = cached_valid && (cached_addr == wanted_addr);

    assign o_valid = rst_n && (state == S_SEND);
    assign o_keep  = 3'b001;

    always_comb begin
        if (input_count == FC0_INPUT_COUNT) begin
            // FC0: 2 words/pixel (C0-C2 | C3); pixel = k/4, ch = k%4
            word_offset = {1'b0, k[12:2], (k[1:0] == 2'd3)};
            byte_lane   = (k[1:0] == 2'd3) ? 2'd0 : k[1:0];
        end else begin
            // later FCs: 3 inputs per word
            word_offset = k_word;
            byte_lane   = k_lane;
        end

        wanted_addr = base_addr + word_offset;

        o_rd_en = rst_n && (state == S_GET) && !cache_hit;
        o_rd_addr = wanted_addr;

        o_data = 24'd0;
        if (state == S_SEND) o_data[7:0] = cached_word[8*byte_lane+:8];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            base_addr    <= 14'd0;
            input_count  <= 13'd0;
            k            <= 13'd0;
            k_word       <= 13'd0;
            k_lane       <= 2'd0;
            cached_valid <= 1'b0;
            cached_addr  <= 14'd0;
            cached_word  <= 24'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (i_tile_start && i_fc_in_count != 0) begin
                        base_addr    <= i_src_base;
                        input_count  <= i_fc_in_count;
                        k            <= 13'd0;
                        k_word       <= 13'd0;
                        k_lane       <= 2'd0;
                        cached_valid <= 1'b0;
                        state        <= S_GET;
                    end
                end
                S_GET: begin
                    state <= cache_hit ? S_SEND : S_WAIT;
                end
                S_WAIT: begin
                    if (i_rd_valid) begin
                        cached_word  <= i_rd_data;
                        cached_addr  <= wanted_addr;
                        cached_valid <= 1'b1;
                        state        <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (o_valid && i_ready) begin
                        if (k == input_count - 1'b1) begin
                            state <= S_IDLE;
                        end else begin
                            k     <= k + 1'b1;
                            if (k_lane == 2'd2) begin
                                k_lane <= 2'd0;
                                k_word <= k_word + 13'd1;
                            end else begin
                                k_lane <= k_lane + 2'd1;
                            end
                            state <= S_GET;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

module MUX (
    input logic i_fc_mode,

    input  logic [23:0] i_pg_data,
    input  logic [ 2:0] i_pg_keep,
    input  logic        i_pg_valid,
    output logic        o_pg_ready,

    input  logic [23:0] i_fc_data,
    input  logic [ 2:0] i_fc_keep,
    input  logic        i_fc_valid,
    output logic        o_fc_ready,

    output logic [23:0] o_data,
    output logic [ 2:0] o_keep,
    output logic        o_valid,
    input  logic        i_ready
);
    assign o_data = i_fc_mode ? i_fc_data : i_pg_data;
    assign o_keep = i_fc_mode ? i_fc_keep : i_pg_keep;
    assign o_valid = i_fc_mode ? i_fc_valid : i_pg_valid;

    assign o_pg_ready = !i_fc_mode && i_ready;
    assign o_fc_ready = i_fc_mode && i_ready;
endmodule

// act_feeder: 1-stage register slice gated by feed_en
module act_feeder (
    input logic clk,
    input logic rst_n,

    input  logic [23:0] i_data,
    input  logic [ 2:0] i_keep,
    input  logic        i_valid,
    output logic        o_ready,
    input  logic        i_feed_en,
    input  logic        i_clear,

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
