`timescale 1ns / 1ps

// ============================================================================
// act_path
//   RAM -> act_ld_unit -> input_buf -+-> act_patch_gen -+
//                                    |                  +-> MUX -> act_feeder -> PE
//                                    +-> fc_gen --------+
// ============================================================================
module act_path (
    input wire clk,
    input wire rst_n,

    // ---- RAM -> input_buf----
    input  wire        i_ld_start,
    input  wire [31:0] i_ram_base,
    input  wire [12:0] i_ld_word_count,
    output wire [11:0] o_ram_rd_addr,
    input  wire [23:0] i_ram_rdata,
    output wire        o_ld_done,

    // ---- cnn_cntl ----
    input wire        i_fc_mode,
    input wire        i_pg_tile_start,
    input wire        i_fc_tile_start,
    input wire [13:0] i_src_base,
    input wire [13:0] i_pos_base,
    input wire [ 5:0] i_in_c,
    input wire [ 6:0] i_in_h,
    input wire [ 6:0] i_in_w,
    input wire [ 1:0] i_stride,
    input wire        i_pad_en,
    input wire [12:0] i_k_total,
    input wire [ 2:0] i_row_mask,
    input wire [12:0] i_fc_in_count,
    input wire        i_feed_en,
    input wire        i_clear,

    // ---- PE array ----
    output wire [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready,

    // ---- result_buf ----
    input wire        i_wr_en,
    input wire [13:0] i_wr_addr,
    input wire [23:0] i_wr_data,
    input wire [ 2:0] i_wr_be
);

    // load -> input_buf
    wire        ibuf_we;
    wire [13:0] ibuf_waddr;
    wire [23:0] ibuf_wdata;
    wire [ 2:0] ibuf_wbe;

    // input_buf read arbitration
    wire pg_rd_en, fc_rd_en;
    wire [13:0] pg_rd_addr, fc_rd_addr;
    wire [23:0] ibuf_rdata;
    wire        ibuf_rvalid;

    wire        ibuf_rd_en = i_fc_mode ? fc_rd_en : pg_rd_en;
    wire [13:0] ibuf_rd_addr = i_fc_mode ? fc_rd_addr : pg_rd_addr;

    // generator -> MUX -> feeder
    wire [23:0] pg_data, fc_data, mux_data;
    wire [2:0] pg_keep, fc_keep, mux_keep;
    wire pg_valid, fc_valid, mux_valid;
    wire pg_ready, fc_ready, mux_ready;

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

module act_ld_unit (
    input wire clk,
    input wire rst_n,

    input wire        i_ld_start,
    input wire [31:0] i_ram_base,
    input wire [12:0] i_ld_word_count,

    output wire [11:0] o_ram_rd_addr,
    input  wire [23:0] i_ram_rdata,

    output wire        o_ibuf_we,
    output wire [13:0] o_ibuf_waddr,
    output wire [23:0] o_ibuf_wdata, // Reverse byte order and flip MSB of each byte (uint8 -> int8 offset)
    output wire [ 2:0] o_ibuf_wbe,

    output reg o_ld_done
);
    localparam S_IDLE = 1'd0, S_WAIT = 1'b1;

    reg state;
    reg [31:0] ram_base;
    reg [12:0] word_count;
    reg [12:0] word_index;

    wire accept_rsp = (state == S_WAIT);
    wire last_word = (word_index == word_count - 13'd1);

    wire [31:0] ram_addr_full = (state == S_IDLE) ? i_ram_base : ram_base 
                + {19'd0, word_index} + 32'd1;

    // Only the low 12 bits are used: requires ram_base + word_count <= 4096
    assign o_ram_rd_addr = ram_addr_full[11:0];

    // Store the current response at the current word_index
    assign o_ibuf_we    = rst_n && accept_rsp;
    assign o_ibuf_waddr = {1'b0, word_index};
    assign o_ibuf_wdata = {i_ram_rdata[7:0],i_ram_rdata[15:8],i_ram_rdata[23:16]} ^ 24'h808080;
    assign o_ibuf_wbe   = 3'b111;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ram_base   <= 32'd0;
            word_count <= 13'd0;
            word_index <= 13'd0;
            o_ld_done  <= 1'b0;
        end else begin
            o_ld_done <= 0;

            case (state)
                // IDLE: Request the first word
                S_IDLE: begin
                    if (i_ld_start) begin
                        ram_base   <= i_ram_base;
                        word_count <= i_ld_word_count;
                        word_index <= 13'd0;

                        if (i_ld_word_count == 0) o_ld_done <= 1;
                        else state <= S_WAIT;
                    end
                end
                // WAIT: Request the next word while receiving the current response
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

module input_buf (
    input wire        clk,
    input wire        rst_n,
    input wire        i_wr_en,
    input wire [13:0] i_wr_addr,
    input wire [23:0] i_wr_data,
    input wire [ 2:0] i_wr_be,

    input wire        i_rd_en,
    input wire [13:0] i_rd_addr,

    output reg [23:0] o_rd_data,
    output reg        o_rd_valid
);
    reg [23:0] mem[0:16383];

    always @(posedge clk) begin
        if (!rst_n) begin
            // reset only the response valid signal
            o_rd_valid <= 1'b0;
        end else begin
            o_rd_valid <= i_rd_en;
            // Write enabled byte lanes
            if (i_wr_en) begin
                if (i_wr_be[0]) mem[i_wr_addr][7:0] <= i_wr_data[7:0];
                if (i_wr_be[1]) mem[i_wr_addr][15:8] <= i_wr_data[15:8];
                if (i_wr_be[2]) mem[i_wr_addr][23:16] <= i_wr_data[23:16];
            end

            if (i_rd_en) o_rd_data <= mem[i_rd_addr];
        end
    end
endmodule


// ============================================================================
// Builds 3x3 conv patches from input_buf via a 2-bank 4x4 window cache
// ============================================================================
module act_patch_gen (
    input wire clk,
    input wire rst_n,

    input wire        i_tile_start,
    input wire [13:0] i_src_base,
    input wire [13:0] i_pos_base,
    input wire [ 5:0] i_in_c,
    input wire [ 6:0] i_in_h,
    input wire [ 6:0] i_in_w,
    
    input wire [ 1:0] i_stride, // stride=1 and does not use this input
    input wire        i_pad_en,
    input wire [12:0] i_k_total,
    input wire [ 2:0] i_row_mask,

    output reg         o_rd_en,
    output reg  [13:0] o_rd_addr,
    input  wire [23:0] i_rd_data,
    input  wire        i_rd_valid,

    output wire [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready
);

    localparam [2:0] S_IDLE     = 3'd0,
                     S_SELECT   = 3'd1,
                     S_CAP_INIT = 3'd2,
                     S_CAP_REQ  = 3'd3,
                     S_CAP_WAIT = 3'd4,
                     S_SEND     = 3'd5;

    reg [2:0] state;

    // ---------------- tile / layer configuration ----------------
    reg [13:0] src_base;
    reg [5:0] in_c;
    reg [6:0] in_h;
    reg [6:0] in_w;
    reg pad_en;
    reg [12:0] k_total;
    reg [2:0] row_mask;
    reg words2;          // 1: 2 words per pixel (Cin=6), 0: 1 word per pixel (Cin=3)
    reg [5:0] wpr;       // Number of windows per row = out_w / 2
    reg [2:0] wpr_sh;    // MSB index of wpr, used for shifting
    reg [5:0] wpr_mask;  // wpr - 1
    reg [2:0] in_w_sh;   // log2(in_w), where in_w is a power of 2 (64 / 32 / 16)
    reg [13:0] base_patch;
    reg [1:0] patch_lane;

    wire signed [15:0] in_w_s16 = {9'd0, in_w};

    // log2 for powers of 2 (1 to 64); otherwise, return the position of the MSB(shift-based timing)
    function [2:0] f_log2_7;
        input [6:0] v;
        begin
            casez (v)
                7'b1zzzzzz: f_log2_7 = 3'd6;
                7'b01zzzzz: f_log2_7 = 3'd5;
                7'b001zzzz: f_log2_7 = 3'd4;
                7'b0001zzz: f_log2_7 = 3'd3;
                7'b00001zz: f_log2_7 = 3'd2;
                7'b000001z: f_log2_7 = 3'd1;
                default:    f_log2_7 = 3'd0;
            endcase
        end
    endfunction

    // ---------------- window cache (2 bank x 32 word) ----------------
    reg [23:0] window_mem[0:63];
    reg [1:0] win_valid;
    reg [11:0] win_tag0, win_tag1;

    // current lane's patch -> window / quadrant
    wire [13:0] cur_patch = base_patch + {12'd0, patch_lane};
    wire [11:0] cur_win = cur_patch[13:2];
    wire cur_bank = cur_win[0];
    wire [11:0] cur_tag = cur_bank ? win_tag1 : win_tag0;
    wire cur_hit = win_valid[cur_bank] && (cur_tag == cur_win);

    // current window position in the output grid
    wire [5:0] win_x = cur_win[5:0] & wpr_mask;
    wire [5:0] win_y = cur_win >> wpr_sh;

    // starting coordinates of the required 4x4 input region
    wire signed [8:0] org_x = $signed(
        {2'b00, win_x, 1'b0}
    ) - (pad_en ? 9'sd1 : 9'sd0);

    wire signed [8:0] org_y = $signed(
        {2'b00, win_y, 1'b0}
    ) - (pad_en ? 9'sd1 : 9'sd0);

    // input pixel index = y * input width + x
    wire signed [15:0] org_L = ($signed({{7{org_y[8]}}, org_y}) <<< in_w_sh) + org_x;

    // ---------------- capture counter ----------------
    reg signed [8:0] cap_x, cap_y;
    reg signed [15:0] cap_lin;
    reg [1:0] cap_cx, cap_cy;
    reg cap_grp;
    // word address within the 4x4 window
    // Cin=3: 1 word per pixel, Cin=6: 2 words per pixel
    wire [4:0] cap_word = words2 ? {cap_cy, cap_cx, cap_grp} : {1'b0, cap_cy, cap_cx};

    wire signed [9:0] in_w_s10 = {3'b000, in_w};
    wire signed [9:0] in_h_s10 = {3'b000, in_h};
    wire cap_in_range = (cap_x >= 0) && (cap_x < in_w_s10) &&
                        (cap_y >= 0) && (cap_y < in_h_s10);
    wire cap_last = (cap_cx == 2'd3) && (cap_cy == 2'd3) && (cap_grp == words2);
    wire cap_adv = ((state == S_CAP_REQ) && !cap_in_range) || ((state == S_CAP_WAIT) && i_rd_valid);

    wire [15:0] cap_lin_sh = words2 ? {cap_lin[14:0], 1'b0} : cap_lin;
    wire [15:0] cap_addr_full = {2'b00, src_base} + cap_lin_sh + {15'd0, cap_grp};

    // ---------------- SEND counter  ----------------
    reg [12:0] send_k;
    reg [1:0] send_kx, send_ky;
    reg  [1:0] send_byte;
    reg        send_grp;
    // group 0: C0~C2, group 1: C3~C5
    wire [5:0] send_ch = (send_grp ? 6'd3 : 6'd0) + {4'd0, send_byte};

    assign o_valid = rst_n && (state == S_SEND) && (row_mask != 3'b000);
    assign o_keep  = row_mask;

    // Calculate the bank and starting position directly from the patch index
    reg [23:0] lane_data;
    reg [13:0] lane_patch;
    reg [3:0] pix;
    reg [5:0] widx;
    integer lane;

    always @(*) begin
        for (lane = 0; lane < 3; lane = lane + 1) begin
            lane_patch = base_patch + lane;

            // Patch starting position (0/1/4/5) + kernel offset
            pix = {1'b0, lane_patch[1], 1'b0, lane_patch[0]}
                + {send_ky, 2'b00}
                + {2'b00, send_kx};

            // Bit 2 of the patch index selects the bank
            widx = words2
                ? {lane_patch[2], pix, send_grp}
                : {lane_patch[2], 1'b0, pix};

            // Select the byte directly without a temporary word
            lane_data[8*lane +: 8] =
                (state == S_SEND && row_mask[lane])
                ? window_mem[widx][8*send_byte +: 8]
                : 8'd0;
        end
    end

    assign o_data = lane_data;

    wire [6:0] out_w_in = i_pad_en ? i_in_w : (i_in_w - 7'd2);
    wire [5:0] wpr_in   = (out_w_in[6:1] == 6'd0) ? 6'd1 : out_w_in[6:1];

    always @(posedge clk or negedge rst_n) begin
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
                // Load tile and layer configuration
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

                // Check window cache for each active patch lane
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

                // Initialize 4x4 window capture
                S_CAP_INIT: begin
                    cap_x   <= org_x;
                    cap_y   <= org_y;
                    cap_lin <= org_L;
                    cap_cx  <= 2'd0;
                    cap_cy  <= 2'd0;
                    cap_grp <= 1'b0;
                    state   <= S_CAP_REQ;
                end

                // Request window data
                S_CAP_REQ: begin
                    if (cap_in_range) begin
                        o_rd_en   <= 1'b1;
                        o_rd_addr <= cap_addr_full[13:0];
                        state     <= S_CAP_WAIT;
                    end else begin
                        window_mem[{cur_bank, cap_word}] <= 24'd0;
                    end
                end

                // Wait for valid input data
                S_CAP_WAIT: begin
                    if (i_rd_valid) begin
                        window_mem[{cur_bank, cap_word}] <= i_rd_data;
                    end
                end

                // Send activation patch data to the feeder when ready
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
            // Advance capture position after storing a word
            if (cap_adv) begin
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
                            // x=3 -> x=0 on next row
                            cap_lin <= cap_lin + in_w_s16 - 16'sd3;
                        end else begin
                            // Move to the next pixel in the same row
                            cap_cx  <= cap_cx + 2'd1;
                            cap_x   <= cap_x + 9'sd1;
                            cap_lin <= cap_lin + 16'sd1;
                        end
                    end
                end
            end
        end
    end
endmodule

module fc_gen (
    input wire clk,
    input wire rst_n,

    input wire        i_tile_start,
    input wire [13:0] i_src_base,
    input wire [12:0] i_fc_in_count,

    output reg         o_rd_en,
    output reg  [13:0] o_rd_addr,
    input  wire [23:0] i_rd_data,
    input  wire        i_rd_valid,

    output reg  [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready
);
    // Conv output 32x32x4
    localparam integer FC0_CHANNELS = 4;
    localparam integer FC0_INPUT_COUNT = 32 * 32 * FC0_CHANNELS;

    localparam [1:0] S_IDLE = 2'd0, S_GET = 2'd1, S_WAIT = 2'd2, S_SEND = 2'd3;

    reg  [ 1:0] state;

    reg  [13:0] base_addr;
    reg  [12:0] input_count;
    reg  [12:0] k;

    reg         cached_valid;
    reg  [13:0] cached_addr;
    reg  [23:0] cached_word;

    reg  [13:0] wanted_addr;

    reg  [12:0] word_offset;
    reg  [ 1:0] byte_lane;
    reg  [12:0] k_word;      // k / 3  
    reg  [ 1:0] k_lane;      // k % 3

    // Skip memory read if the required word is cached
    wire cache_hit = cached_valid && (cached_addr == wanted_addr);

    assign o_valid = rst_n && (state == S_SEND);
    assign o_keep  = 3'b001;

    always @(*) begin
        if (input_count == FC0_INPUT_COUNT) begin
            // 2 words per pixel: C0-C2 / C3, pixel index = k / 4, channel index = k % 4
            word_offset = {1'b0, k[12:2], (k[1:0] == 2'd3)};
            // 0 if C3, otherwise the channel index
            byte_lane   = (k[1:0] == 2'd3) ? 2'd0 : k[1:0];
        end else begin
            word_offset = k_word;
            byte_lane   = k_lane;
        end

        wanted_addr = base_addr + word_offset;

        o_rd_en = rst_n && (state == S_GET) && !cache_hit;
        o_rd_addr = wanted_addr;

        o_data = 24'd0;
        if (state == S_SEND) o_data[7:0] = cached_word[8*byte_lane+:8];
    end

    always @(posedge clk or negedge rst_n) begin
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
                // Check cache hit and request data on a miss
                S_GET: begin
                    state <= cache_hit ? S_SEND : S_WAIT;
                end
                // Wait for memory response and cache the received word
                S_WAIT: begin
                    if (i_rd_valid) begin
                        cached_word  <= i_rd_data;
                        cached_addr  <= wanted_addr;
                        cached_valid <= 1'b1;
                        state        <= S_SEND;
                    end
                end
                // Send cached data and advance to the next input
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

// Select generator output by mode; ready goes only to the active source
module MUX (
    input wire i_fc_mode,

    input  wire [23:0] i_pg_data,
    input  wire [ 2:0] i_pg_keep,
    input  wire        i_pg_valid,
    output wire        o_pg_ready,

    input  wire [23:0] i_fc_data,
    input  wire [ 2:0] i_fc_keep,
    input  wire        i_fc_valid,
    output wire        o_fc_ready,

    output wire [23:0] o_data,
    output wire [ 2:0] o_keep,
    output wire        o_valid,
    input  wire        i_ready
);
    assign o_data = i_fc_mode ? i_fc_data : i_pg_data;
    assign o_keep = i_fc_mode ? i_fc_keep : i_pg_keep;
    assign o_valid = i_fc_mode ? i_fc_valid : i_pg_valid;

    assign o_pg_ready = !i_fc_mode && i_ready;
    assign o_fc_ready = i_fc_mode && i_ready;
endmodule

// Output register stage between the generator and the PE array
module act_feeder (
    input wire clk,
    input wire rst_n,

    input  wire [23:0] i_data,
    input  wire [ 2:0] i_keep,
    input  wire        i_valid,
    output wire        o_ready,
    input  wire        i_feed_en,
    input  wire        i_clear,

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