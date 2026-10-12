`timescale 1ns / 1ps
`include "cnn_defs.vh"

module cnn_cntl #(
    parameter integer NUM_LAYERS = 4,
    parameter integer WBUF_WORDS = 256,

    // Two regions of input_buf are used alternately between layers.
    parameter [`ACT_AW-1:0] REGION_A_BASE = 14'd0,
    parameter [`ACT_AW-1:0] REGION_B_BASE = 14'd8192,

    // Layer 0: Conv0 3x3 3->6, S=1, P=1, ReLU, output MaxPool
    parameter [   `DIM_W-1:0] L0_IN_W       = 7'd64,
    parameter [   `DIM_W-1:0] L0_IN_H       = 7'd64,
    parameter [    `CH_W-1:0] L0_IN_C       = 6'd3,
    parameter [   `DIM_W-1:0] L0_OUT_W      = 7'd64,
    parameter [   `DIM_W-1:0] L0_OUT_H      = 7'd64,
    parameter [    `CH_W-1:0] L0_OUT_C      = 6'd6,
    parameter [          1:0] L0_STRIDE     = 2'd1,
    parameter                 L0_PAD_EN     = 1'b1,
    parameter [     `K_W-1:0] L0_K          = 13'd27,
    parameter [     `K_W-1:0] L0_OUT_PIX    = 13'd4096,
    parameter [    `W_AW-1:0] L0_W_BASE     = 16'd0,
    parameter [`PARAM_AW-1:0] L0_PARAM_BASE = 7'd0,
    parameter                 L0_RELU       = 1'b1,
    parameter                 L0_POOL_EN    = 1'b1,

    // Layer 1 : Conv1 3x3 6->4, S=1, P=1, ReLU
    parameter [   `DIM_W-1:0] L1_IN_W       = 7'd32,
    parameter [   `DIM_W-1:0] L1_IN_H       = 7'd32,
    parameter [    `CH_W-1:0] L1_IN_C       = 6'd6,
    parameter [   `DIM_W-1:0] L1_OUT_W      = 7'd32,
    parameter [   `DIM_W-1:0] L1_OUT_H      = 7'd32,
    parameter [    `CH_W-1:0] L1_OUT_C      = 6'd4,
    parameter [          1:0] L1_STRIDE     = 2'd1,
    parameter                 L1_PAD_EN     = 1'b1,
    parameter [     `K_W-1:0] L1_K          = 13'd54,
    parameter [     `K_W-1:0] L1_OUT_PIX    = 13'd1024,
    parameter [    `W_AW-1:0] L1_W_BASE     = 16'd54,
    parameter [`PARAM_AW-1:0] L1_PARAM_BASE = 7'd6,
    parameter                 L1_RELU       = 1'b1,
    parameter                 L1_POOL_EN    = 1'b0,

    // Layer 2 : fc1  4096 -> 32, ReLU
    // FC input is stored in HWC order; skip padded lanes when reading.
    parameter [   `DIM_W-1:0] L2_IN_W       = 7'd32,
    parameter [   `DIM_W-1:0] L2_IN_H       = 7'd32,
    parameter [    `CH_W-1:0] L2_IN_C       = 6'd4,
    parameter [     `K_W-1:0] L2_K          = 13'd4096,
    parameter [    `CH_W-1:0] L2_OUT_C      = 6'd32,
    parameter [    `W_AW-1:0] L2_W_BASE     = 16'd162,
    parameter [`PARAM_AW-1:0] L2_PARAM_BASE = 7'd10,
    parameter                 L2_RELU       = 1'b1,

    // Layer 3: fc2 32 -> 1, final regression
    parameter [   `DIM_W-1:0] L3_IN_W       = 7'd1,
    parameter [   `DIM_W-1:0] L3_IN_H       = 7'd1,
    parameter [    `CH_W-1:0] L3_IN_C       = 6'd32,
    parameter [     `K_W-1:0] L3_K          = 13'd32,
    parameter [    `CH_W-1:0] L3_OUT_C      = 6'd1,
    parameter [    `W_AW-1:0] L3_W_BASE     = 16'd45218,
    parameter [`PARAM_AW-1:0] L3_PARAM_BASE = 7'd42,
    parameter                 L3_RELU       = 1'b0,

    // Per-layer requantization: q = sat_int8(round((acc + bias) * M / 2^S)).
    parameter [31:0] L0_QM = 32'd3157292,
    parameter [ 5:0] L0_QS = 6'd30,
    parameter [31:0] L1_QM = 32'd11411101,
    parameter [ 5:0] L1_QS = 6'd30,
    parameter [31:0] L2_QM = 32'd3791004,
    parameter [ 5:0] L2_QS = 6'd30,
    parameter [31:0] L3_QM = 32'd7489321,
    parameter [ 5:0] L3_QS = 6'd30
) (
    input wire clk,
    input wire rst_n,

    // ---- AXI4-Lite CSR / RAM --------------------------------------
    input  wire                 i_start_valid,
    output wire                 o_start_ready,
    output wire                 o_busy,
    output wire                 o_ram_owner,
    output wire [`PARAM_AW-1:0] o_param_mem_addr,
    input  wire [         31:0] i_param_mem_data,

    // ---- pe_cntl : tile cmd -------------
    output wire               o_tile_valid,
    input  wire               i_tile_ready,
    output wire [   `K_W-1:0] o_step_total,
    output wire [`KEEP_W-1:0] o_tile_row_mask,
    output wire [`KEEP_W-1:0] o_tile_col_mask,

    // ---- pe_cntl: Reload chunks (only fc1 with K>256; 15 times/tile and 165 times/inference) ----
    // Prefetch the next weight chunk into the other buffer half while PE is running.
    input  wire i_chunk_req,
    output wire o_chunk_loaded,

    // ---- act_ld_unit -------------------------------------------------------
    output reg             o_ld_start,
    input  wire            i_ld_done,
    output reg             o_write_grant,

    // ---- act_patch_gen / fc_gen / MUX: Layer descriptor ----
    output reg                o_layer_cfg_valid,
    output wire [`ACT_AW-1:0] o_src_base,
    output wire [ `DIM_W-1:0] o_in_w,
    output wire [ `DIM_W-1:0] o_in_h,
    output wire [  `CH_W-1:0] o_in_c,
    output wire [        1:0] o_stride,
    output wire               o_pad_en,
    output wire [   `K_W-1:0] o_k_total,
    output wire               o_fc_mode,

    // ---- act_patch_gen / fc_gen: Tile ----
    output reg                o_pg_tile_start,
    output reg                o_fc_tile_start,
    output wire [ `POS_W-1:0] o_pos_base,
    output wire [`KEEP_W-1:0] o_row_mask,

    // ---- wgt_ld_unit / wgt_patch_gen ---------------------------------------
    output wire                o_wload_start,
    input  wire                i_wload_ready,
    output wire [   `W_AW-1:0] o_mem_base,
    output wire [`CHUNK_W-1:0] o_chunk_word_count,
    output wire                o_buf_half,
    input  wire                i_wload_done,

    // ---- out_path ----------------------------------------------------------
    output wire                 o_tile_cfg_valid,
    output wire                 o_is_final_layer,
    output wire                 o_pool_en,
    output wire [   `DIM_W-1:0] o_conv_w,
    output wire [   `DIM_W-1:0] o_conv_h,
    output wire [    `CH_W-1:0] o_out_channels,
    output wire [  `ACT_AW-1:0] o_dst_base,
    output wire                 o_relu_en,
    output wire [         31:0] o_quant_multiplier,
    output wire [          5:0] o_quant_shift,
    output wire [`PARAM_AW-1:0] o_bias_base,
    output wire [   `OCB_W-1:0] o_out_ch_base,
    output wire [  `KEEP_W-1:0] o_col_mask,
    output wire                 o_tile_last,
    output reg                  o_param_load_start,
    input  wire                 i_param_load_done,
    input  wire                 i_params_ready,
    output wire                 o_param_wr_en,
    output wire [`PARAM_AW-1:0] o_param_wr_addr,
    output wire [         31:0] o_param_wr_data,
    input  wire                 i_tile_in_done,
    input  wire                 i_layer_done,
    input  wire                 i_done_status,

    // ---- Debug ----
    output wire [2:0] o_layer_idx,
    output wire [3:0] o_state
);

    // FSM
    // State values follow the execution order.
    localparam [3:0] C_IDLE = 4'd0;
    localparam [3:0] C_START = 4'd1;
    localparam [3:0] C_PARAM_LOAD = 4'd2;
    localparam [3:0] C_SET = 4'd3;
    localparam [3:0] C_W_LOAD = 4'd4;
    localparam [3:0] C_TILE_CFG = 4'd5;
    localparam [3:0] C_PE_TILE = 4'd6;
    localparam [3:0] C_PE_WAIT = 4'd7;
    localparam [3:0] C_NXT_TILE = 4'd8;
    localparam [3:0] C_LAYER_END = 4'd9;
    localparam [3:0] C_DONE = 4'd10;

    reg [       3:0] state;
    reg [       2:0] layer_idx;
    reg              region_sel;  // Swap input/output regions after each layer.

    // Process three positions and three output channels per tile.
    reg [`POS_W-1:0] pos_group;
    reg [`OCG_W-1:0] oc_group;
    reg [ `W_AW-1:0] og_off_q;

    reg              tile_started;
    reg              tcfg_sent;
    reg              first_chunk_rdy;
    reg              tile_in_done_seen;
    reg              layer_done_seen;
    reg              ld_done_seen;

    assign o_busy        = (state != C_IDLE);
    assign o_layer_idx   = layer_idx;
    assign o_state       = state;
    assign o_start_ready = (state == C_IDLE) && !i_done_status;

    // =========================================================================
    // Layer Setting by config
    // =========================================================================
    reg [`DIM_W-1:0] ly_in_w, ly_in_h, ly_out_w, ly_out_h;
    reg [`CH_W-1:0] ly_in_c, ly_out_c;
    reg [1:0] ly_stride;
    reg       ly_pad_en;
    reg [`K_W-1:0] ly_k, ly_out_pix;
    reg [    `W_AW-1:0] ly_w_base;
    reg [`PARAM_AW-1:0] ly_param_base;
    reg ly_relu, ly_pool_en, ly_is_fc;
    reg [31:0] ly_qm;
    reg [ 5:0] ly_qs;  // Current layer requantization M/S.

    always @* begin
        ly_in_w = 7'd1;
        ly_in_h = 7'd1;
        ly_in_c = 6'd1;
        ly_out_w = 7'd1;
        ly_out_h = 7'd1;
        ly_out_c = 6'd1;
        ly_stride = 2'd1;
        ly_pad_en = 1'b0;
        ly_k = 13'd1;
        ly_out_pix = 13'd1;
        ly_w_base = {`W_AW{1'b0}};
        ly_param_base = {`PARAM_AW{1'b0}};
        ly_relu = 1'b0;
        ly_pool_en = 1'b0;
        ly_is_fc = 1'b1;
        ly_qm = 32'h4000_0000;
        ly_qs = 6'd30;

        case (layer_idx)  // layer setting
            3'd0: begin  // Conv0 : L0_* = 64x64x3 -> 64x64x6, K 27, out_pix 4096, w_base 0, param_base 0, ReLU, Pool
                ly_in_w = L0_IN_W;
                ly_in_h = L0_IN_H;
                ly_in_c = L0_IN_C;
                ly_out_w = L0_OUT_W;
                ly_out_h = L0_OUT_H;
                ly_out_c = L0_OUT_C;
                ly_stride = L0_STRIDE;
                ly_pad_en = L0_PAD_EN;
                ly_k = L0_K;
                ly_out_pix = L0_OUT_PIX;
                ly_w_base = L0_W_BASE;
                ly_param_base = L0_PARAM_BASE;
                ly_relu = L0_RELU;
                ly_pool_en = L0_POOL_EN;
                ly_is_fc = 1'b0;
                ly_qm = L0_QM;
                ly_qs = L0_QS;
            end
            3'd1: begin  // Conv1 : L1_* = 32x32x6 -> 32x32x4, K 54, out_pix 1024, w_base 54, param_base 6, ReLU
                ly_in_w = L1_IN_W;
                ly_in_h = L1_IN_H;
                ly_in_c = L1_IN_C;
                ly_out_w = L1_OUT_W;
                ly_out_h = L1_OUT_H;
                ly_out_c = L1_OUT_C;
                ly_stride = L1_STRIDE;
                ly_pad_en = L1_PAD_EN;
                ly_k = L1_K;
                ly_out_pix = L1_OUT_PIX;
                ly_w_base = L1_W_BASE;
                ly_param_base = L1_PARAM_BASE;
                ly_relu = L1_RELU;
                ly_pool_en = L1_POOL_EN;
                ly_is_fc = 1'b0;
                ly_qm = L1_QM;
                ly_qs = L1_QS;
            end
            3'd2: begin  // fc1: L2_*, 32x32x4 -> 32, K=4096, out_pix=1 (fixed), w_base=162, param_base=10, ReLU.
                ly_in_w = L2_IN_W;
                ly_in_h = L2_IN_H;
                ly_in_c = L2_IN_C;
                ly_out_w = 7'd1;
                ly_out_h = 7'd1;
                ly_out_c = L2_OUT_C;
                ly_k = L2_K;
                ly_out_pix = 13'd1;
                ly_w_base = L2_W_BASE;
                ly_param_base = L2_PARAM_BASE;
                ly_relu = L2_RELU;
                ly_is_fc = 1'b1;
                ly_qm = L2_QM;
                ly_qs = L2_QS;
            end
            default: begin // fc2: L3_*, 32 -> 1, K=32, out_pix=1 (fixed), w_base=45218, param_base=42; no ReLU.
                ly_in_w = L3_IN_W;
                ly_in_h = L3_IN_H;
                ly_in_c = L3_IN_C;
                ly_out_w = 7'd1;
                ly_out_h = 7'd1;
                ly_out_c = L3_OUT_C;
                ly_k = L3_K;
                ly_out_pix = 13'd1;
                ly_w_base = L3_W_BASE;
                ly_param_base = L3_PARAM_BASE;
                ly_relu = L3_RELU;
                ly_is_fc = 1'b1;
                ly_qm = L3_QM;
                ly_qs = L3_QS;
            end
        endcase
    end

    // ly_* below are L0_*..L3_* values selected by layer_idx in the case above.
    // Parentheses show actual L0/L1/L2/L3 (Conv0/Conv1/fc1/fc2) values.
    assign o_in_w             = ly_in_w;
    assign o_in_h             = ly_in_h;
    assign o_in_c             = ly_in_c;
    assign o_out_channels     = ly_out_c;
    assign o_stride           = ly_stride;
    assign o_pad_en           = ly_pad_en;
    assign o_k_total          = ly_k;
    assign o_relu_en          = ly_relu;
    assign o_pool_en          = ly_pool_en;
    assign o_quant_multiplier = ly_qm;
    assign o_quant_shift      = ly_qs;
    assign o_bias_base        = ly_param_base;
    assign o_fc_mode          = ly_is_fc;
    assign o_is_final_layer   = (layer_idx == (NUM_LAYERS - 1));

    assign o_conv_w           = ly_out_w;
    assign o_conv_h           = ly_out_h;

    assign o_step_total    = ly_k;
    assign o_tile_row_mask = o_row_mask;
    assign o_tile_col_mask = o_col_mask;

    assign o_src_base      = region_sel ? REGION_B_BASE : REGION_A_BASE;
    assign o_dst_base      = region_sel ? REGION_A_BASE : REGION_B_BASE;

    // Tile Decode
    function [2:0] lane_mask;
        input [`K_W-1:0] total;
        input [`K_W-1:0] base;
        reg [`K_W-1:0] remain;
        begin
            if (total <= base) lane_mask = 3'b000;
            else begin
                remain = total - base;
                if (remain >= 3) lane_mask = 3'b111;
                else if (remain == 2) lane_mask = 3'b011;
                else lane_mask = 3'b001;
            end
        end
    endfunction

    wire [`K_W-1:0] pos_base_k = {{(`K_W - `POS_W) {1'b0}}, pos_group} * 13'd3;
    wire [`K_W-1:0] oc_base_k = {{(`K_W - `OCG_W) {1'b0}}, oc_group} * 13'd3;
    wire [`K_W-1:0] out_c_k = {{(`K_W - `CH_W) {1'b0}}, ly_out_c};

    assign o_pos_base    = pos_base_k[`POS_W-1:0];
    assign o_out_ch_base = oc_base_k[`OCB_W-1:0];
    // Register masks to shorten the combinational path to output_fifo.
    reg [`KEEP_W-1:0] row_mask_r, col_mask_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_mask_r <= {`KEEP_W{1'b0}};
            col_mask_r <= {`KEEP_W{1'b0}};
        end else begin
            row_mask_r <= lane_mask(ly_out_pix, pos_base_k);
            col_mask_r <= lane_mask(out_c_k, oc_base_k);
        end
    end
    assign o_row_mask = row_mask_r;
    assign o_col_mask = col_mask_r;

    wire pos_last = ((pos_base_k + 13'd3) >= ly_out_pix);
    wire oc_last = ((oc_base_k + 13'd3) >= out_c_k);
    assign o_tile_last = pos_last && oc_last;

    // First and subsequent weight chunks use the same loader.
    localparam [1:0] W_IDLE = 2'd0;
    localparam [1:0] W_ISSUE = 2'd1;
    localparam [1:0] W_WAIT = 2'd2;
    localparam [1:0] W_REPLY = 2'd3;

    reg [1:0] wsvc;
    reg [`K_W-1:0] svc_kbase;
    reg [`CHUNK_W-1:0] svc_len;

    // Reuse cached weights for short layers; alternate halves for fc1.
    reg buf_half;
    reg wtag_valid[0:1];
    reg [2:0] wtag_layer[0:1];
    reg [`OCG_W-1:0] wtag_oc[0:1];
    wire first_half = (ly_k > WBUF_WORDS) ? 1'b0 : oc_group[0];
    wire wload_skip = wtag_valid[first_half] && (wtag_layer[first_half] == layer_idx) &&
                      (wtag_oc[first_half] == oc_group) && (ly_k <= WBUF_WORDS);

    function [`CHUNK_W-1:0] chunk_len;
        input [`K_W-1:0] remain;
        begin
            chunk_len = (remain > WBUF_WORDS) ? WBUF_WORDS[`CHUNK_W-1:0] : remain[`CHUNK_W-1:0];
        end
    endfunction

    wire [`CHUNK_W-1:0] first_len = chunk_len(ly_k);

    wire [`K_W-1:0]     nx_kbase = svc_kbase + {{(`K_W-`CHUNK_W){1'b0}}, svc_len};
    wire [`CHUNK_W-1:0] nx_len = chunk_len(ly_k - nx_kbase);

    wire chunk_accept = (state == C_PE_WAIT) && (wsvc == W_IDLE) && i_chunk_req;

    // Weight address = layer base + channel-group offset + chunk offset.
    wire [`W_AW-1:0] k_ext = {{(`W_AW - `K_W) {1'b0}}, ly_k};
    wire [`W_AW-1:0] kb_ext = {{(`W_AW - `K_W) {1'b0}}, svc_kbase};
    wire [`W_AW-1:0] og_off = og_off_q;
    assign o_mem_base         = ly_w_base + og_off + kb_ext;

    assign o_wload_start      = (wsvc == W_ISSUE) && i_wload_ready;
    assign o_chunk_word_count = svc_len;
    assign o_chunk_loaded     = (wsvc == W_REPLY);
    assign o_buf_half         = buf_half;

    // Load all biases once before starting the layer loop.
    // Parameter RAM returns data one clock after the read address.
    localparam [`PARAM_AW:0] PARAM_TOTAL =
          (NUM_LAYERS <= 1) ? (L0_PARAM_BASE + L0_OUT_C) :
          (NUM_LAYERS == 2) ? (L1_PARAM_BASE + L1_OUT_C) :
          (NUM_LAYERS == 3) ? (L2_PARAM_BASE + L2_OUT_C) :
                              (L3_PARAM_BASE + L3_OUT_C);

    reg [`PARAM_AW:0] pl_idx;
    reg pl_busy;
    reg pl_done;
    reg [`PARAM_AW-1:0] pl_addr_q;

    wire pl_more = (pl_idx < PARAM_TOTAL);

    assign o_ram_owner = (state == C_PARAM_LOAD);

    assign o_param_mem_addr = pl_idx[`PARAM_AW-1:0];

    wire pmem_req_fire = (state == C_PARAM_LOAD) && pl_more && !pl_busy;
    wire pmem_rsp_fire = pl_busy;

    assign o_param_wr_en = pmem_rsp_fire;
    assign o_param_wr_addr = pl_addr_q;
    assign o_param_wr_data = i_param_mem_data;

    assign o_tile_valid = (state == C_PE_TILE) && tile_started;

    // Send tile configuration only when the PE can accept a new tile.
    assign o_tile_cfg_valid = (state == C_TILE_CFG) && !tcfg_sent && i_tile_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= C_IDLE;
            layer_idx          <= 3'd0;
            region_sel         <= 1'b0;
            pos_group          <= {`POS_W{1'b0}};
            oc_group           <= {`OCG_W{1'b0}};
            og_off_q           <= {`W_AW{1'b0}};
            tile_started       <= 1'b0;
            tcfg_sent          <= 1'b0;
            first_chunk_rdy    <= 1'b0;
            tile_in_done_seen  <= 1'b0;
            layer_done_seen    <= 1'b0;
            o_ld_start         <= 1'b0;
            o_param_load_start <= 1'b0;
            ld_done_seen       <= 1'b0;
            o_write_grant      <= 1'b0;
            o_layer_cfg_valid  <= 1'b0;
            o_pg_tile_start    <= 1'b0;
            o_fc_tile_start    <= 1'b0;
            wsvc               <= W_IDLE;
            svc_kbase          <= {`K_W{1'b0}};
            svc_len            <= {`CHUNK_W{1'b0}};
            buf_half           <= 1'b0;
            wtag_valid[0]      <= 1'b0;
            wtag_valid[1]      <= 1'b0;
            wtag_layer[0]      <= 3'd0;
            wtag_layer[1]      <= 3'd0;
            wtag_oc[0]         <= {`OCG_W{1'b0}};
            wtag_oc[1]         <= {`OCG_W{1'b0}};
            pl_idx             <= {(`PARAM_AW + 1) {1'b0}};
            pl_busy            <= 1'b0;
            pl_done            <= 1'b0;
            pl_addr_q          <= {`PARAM_AW{1'b0}};
        end else begin
            o_ld_start    <= 1'b0;
            o_param_load_start <= 1'b0;
            o_layer_cfg_valid <= 1'b0;
            o_pg_tile_start   <= 1'b0;
            o_fc_tile_start   <= 1'b0;

            if (i_tile_in_done) tile_in_done_seen <= 1'b1;
            if (i_layer_done) layer_done_seen <= 1'b1;
            if (i_ld_done) ld_done_seen <= 1'b1;

            // =================================================================
            // Weight Load
            // =================================================================
            case (wsvc)
                W_IDLE: begin
                    if (chunk_accept) begin
                        svc_kbase <= nx_kbase;
                        svc_len   <= nx_len;
                        buf_half  <= ~buf_half;
                        wsvc      <= W_ISSUE;
                    end
                end
                W_ISSUE: if (i_wload_ready) wsvc <= W_WAIT;
                W_WAIT:
                if (i_wload_done) begin
                    if (state == C_PE_WAIT) begin
                        wtag_valid[buf_half] <= 1'b0;
                        wsvc <= W_REPLY;
                    end else begin
                        first_chunk_rdy      <= 1'b1;
                        wtag_valid[buf_half] <= 1'b1;
                        wtag_layer[buf_half] <= layer_idx;
                        wtag_oc[buf_half]    <= oc_group;
                        wsvc                 <= W_IDLE;
                    end
                end
                default: wsvc <= W_IDLE;
            endcase

            // =================================================================
            // Parameter Load
            // =================================================================
            if (pmem_req_fire) begin
                pl_busy   <= 1'b1;
                pl_addr_q <= o_param_mem_addr;
                pl_idx    <= pl_idx + 1'b1;
            end
            if (pmem_rsp_fire) begin
                pl_busy <= 1'b0;
            end
            if (i_param_load_done) pl_done <= 1'b1;

            // =================================================================
            // Main FSM
            // =================================================================
            case (state)
                C_IDLE: begin
                    o_write_grant <= 1'b0;
                    wtag_valid[0] <= 1'b0;
                    wtag_valid[1] <= 1'b0;
                    ld_done_seen  <= 1'b0;
                    if (i_start_valid && o_start_ready) begin
                        o_ld_start <= 1'b1;         // Image RAM -> input_buf
                        state      <= C_START;
                    end
                end

                C_START: begin // Image Load State
                    if (i_ld_done || ld_done_seen) begin
                        ld_done_seen       <= 1'b0;
                        o_write_grant      <= 1'b1;
                        layer_idx          <= 3'd0;
                        region_sel         <= 1'b0;
                        pl_idx             <= {(`PARAM_AW + 1) {1'b0}};
                        pl_busy            <= 1'b0;
                        pl_done            <= 1'b0;
                        o_param_load_start <= 1'b1;
                        state              <= C_PARAM_LOAD;
                    end
                end

                C_PARAM_LOAD: begin // one load per inference - RAM owner = param (1)
                    if (pl_done) state <= C_SET;
                end

                C_SET: begin // layer descriptor + output path setting
                    o_layer_cfg_valid <= 1'b1;
                    pos_group         <= {`POS_W{1'b0}};
                    oc_group          <= {`OCG_W{1'b0}};
                    og_off_q          <= {`W_AW{1'b0}};
                    tile_started      <= 1'b0;
                    tcfg_sent         <= 1'b0;
                    first_chunk_rdy   <= 1'b0;
                    tile_in_done_seen <= 1'b0;
                    layer_done_seen   <= 1'b0;
                    state             <= C_W_LOAD;
                end

                C_W_LOAD: begin // this tile's first weight chunk - RAM owner = weight (0)
                    buf_half <= first_half;
                    if (wload_skip) begin
                        first_chunk_rdy <= 1'b1;
                    end else if (!first_chunk_rdy && (wsvc == W_IDLE)) begin
                        svc_kbase <= {`K_W{1'b0}};
                        svc_len   <= first_len;
                        wsvc      <= W_ISSUE;
                    end

                    if (first_chunk_rdy && (wsvc == W_IDLE)) begin
                        state <= C_TILE_CFG;
                    end
                end

                // Wait for parameters after tile configuration has been accepted.
                C_TILE_CFG: begin // param_buf -> post_process
                    if (!tcfg_sent) begin
                        if (i_tile_ready) tcfg_sent <= 1'b1;
                    end else if (i_params_ready) begin
                        tile_started <= 1'b0;
                        state        <= C_PE_TILE;
                    end
                end

                C_PE_TILE: begin
                    if (!tile_started) begin
                        if (ly_is_fc) o_fc_tile_start <= 1'b1;
                        else o_pg_tile_start <= 1'b1;
                        tile_started      <= 1'b1;
                        tile_in_done_seen <= 1'b0;
                    end else if (i_tile_ready) begin
                        state <= C_PE_WAIT;
                    end
                end

                // Chunk reloads are handled by the weight-load FSM above.
                C_PE_WAIT: begin
                    if ((i_tile_in_done || tile_in_done_seen) && i_tile_ready)
                        state <= C_NXT_TILE;
                end

                // Finish all channel groups before moving to the next position.
                C_NXT_TILE: begin
                    tile_started      <= 1'b0;
                    tcfg_sent         <= 1'b0;
                    first_chunk_rdy   <= 1'b0;
                    tile_in_done_seen <= 1'b0;

                    if (!oc_last) begin
                        oc_group <= oc_group + 1'b1;
                        og_off_q <= og_off_q + k_ext;
                        state <= C_W_LOAD;
                    end else if (!pos_last) begin
                        oc_group <= {`OCG_W{1'b0}};
                        og_off_q <= {`W_AW{1'b0}};
                        pos_group <= pos_group + 1'b1;
                        state <= C_W_LOAD;
                    end else begin
                        state <= C_LAYER_END;
                    end
                end

                C_LAYER_END: begin // Pool/Bypass result & store
                    if (i_layer_done || layer_done_seen) begin
                        layer_done_seen <= 1'b0;
                        if (layer_idx == (NUM_LAYERS - 1)) begin
                            state <= C_DONE;
                        end else begin
                            region_sel <= ~region_sel;
                            layer_idx  <= layer_idx + 1'b1;
                            state      <= C_SET;
                        end
                    end
                end

                default: begin // C_DONE
                    o_write_grant <= 1'b0;
                    state         <= C_IDLE;
                end
            endcase
        end
    end

    // synthesis translate_off
    reg [8*12-1:0] state_name;
    reg [ 8*8-1:0] wsvc_name;
    reg [ 8*5-1:0] layer_name;
    reg [8*16-1:0] tile_name;
    always @* begin
        case (layer_idx)
            3'd0:    layer_name = "Conv0";
            3'd1:    layer_name = "Conv1";
            3'd2:    layer_name = "fc1";
            3'd3:    layer_name = "fc2";
            default: layer_name = "L?";
        endcase
        $sformat(tile_name, "L%0d p%0d oc%0d", layer_idx, pos_group, oc_group);
        case (state)
            C_IDLE:       state_name = "C_IDLE";
            C_START:      state_name = "C_START";
            C_PARAM_LOAD: state_name = "C_PARAM_LOAD";
            C_SET:        state_name = "C_SET";
            C_W_LOAD:     state_name = "C_W_LOAD";
            C_TILE_CFG:   state_name = "C_TILE_CFG";
            C_PE_TILE:    state_name = "C_PE_TILE";
            C_PE_WAIT:    state_name = "C_PE_WAIT";
            C_NXT_TILE:   state_name = "C_NXT_TILE";
            C_LAYER_END:  state_name = "C_LAYER_END";
            C_DONE:       state_name = "C_DONE";
            default:      state_name = "C_???";
        endcase
        case (wsvc)
            W_IDLE:  wsvc_name = "W_IDLE";
            W_ISSUE: wsvc_name = "W_ISSUE";
            W_WAIT:  wsvc_name = "W_WAIT";
            default: wsvc_name = "W_REPLY";
        endcase
    end
    // synthesis translate_on
endmodule

module pe_cntl #(
    parameter integer WBUF_WORDS = 256 // 256 words per wgt_buf half = maximum chunk length
) (
    input wire clk,
    input wire rst_n,

    // ---- cnn_cntl: Tile command (direct connection inside top_cnn_cntl) ----
    input  wire               i_tile_valid,
    output wire               o_tile_ready,
    input  wire [   `K_W-1:0] i_step_total,
    input  wire [`KEEP_W-1:0] i_tile_row_mask,
    input  wire [`KEEP_W-1:0] i_tile_col_mask,

    // ---- cnn_cntl: Intermediate chunk reload (only for K>256) ----
    output wire o_chunk_req,
    input  wire i_chunk_loaded,

    // ---- wgt_ld_unit -------------------------------------------------------
    output wire o_wbuf_free,

    // ---- wgt_patch_gen -----------------------------------------------------
    output wire                o_chunk_start,
    output wire [`CHUNK_W-1:0] o_chunk_word_count,
    input  wire                i_chunk_done,

    // ---- act_feeder / wgt_feeder -------------------------------------------
    output wire o_feed_en,
    output wire o_tile_clear,
    input  wire i_weight_valid,
    input  wire i_act_valid,

    // ---- pe_core -----------------------------------------------------------
    output wire             o_step_en,
    output wire             o_feed_valid,
    output wire             o_acc_clear,
    output wire [`PE_N-1:0] o_mac_valid,
    output wire [`PE_N-1:0] o_mac_last,

    // ---- out_path ----------------------------------------------------------
    input wire i_result_space_ready,
    input wire i_tile_in_done
);
    localparam [2:0] P_IDLE = 3'd0;
    localparam [2:0] P_CLEAR = 3'd1;
    localparam [2:0] P_PREFILL = 3'd2;
    localparam [2:0] P_FEED = 3'd3;
    localparam [2:0] P_CHUNK_WAIT = 3'd4;
    localparam [2:0] P_DRAIN = 3'd5;
    localparam [2:0] P_DONE = 3'd6;

    localparam [`K_W-1:0] K_ONE = 1;
    localparam [`CHUNK_W-1:0] C_ONE = 1;

     // Chunk length = min(remaining beats, WBUF_WORDS=256). K=27 -> 27; K=4096 -> 256 each.
    function [`CHUNK_W-1:0] chunk_len;
        input [`K_W-1:0] remain;
        begin
            chunk_len = (remain > WBUF_WORDS) ? WBUF_WORDS[`CHUNK_W-1:0] : remain[`CHUNK_W-1:0];
        end
    endfunction

    reg [2:0] state;
    reg [`K_W-1:0] k_left;
    reg [`CHUNK_W-1:0] c_left;
    reg [`CHUNK_W-1:0] cur_len;
    reg [`KEEP_W-1:0] row_mask_q;
    reg [`KEEP_W-1:0] col_mask_q;
    reg reader_done_seen;
    reg next_req;
    reg next_ready;
    reg tile_in_done_seen;
    reg space_seen;
    reg [4:0] valid_pipe;
    reg [4:0] last_pipe;

    wire inject = (state == P_FEED) && i_act_valid && i_weight_valid;
    wire drain_advance = (state == P_DRAIN);
    wire tile_last_beat = (k_left == K_ONE);
    wire chunk_last_beat = (c_left == C_ONE);
    wire feeding = (state == P_PREFILL) || (state == P_FEED);
    wire clearing = (state == P_CLEAR);

    // Avoid a zero-length tile.
    wire [`K_W-1:0] k_init = (i_step_total == {`K_W{1'b0}}) ? K_ONE : i_step_total;

    // Remember collector readiness across tile_cfg to avoid a handshake deadlock.
    assign o_tile_ready = (state == P_IDLE) && (i_result_space_ready || space_seen);

    // Request the next chunk as soon as the current chunk starts.
    assign o_chunk_req = next_req;

    wire rd_active = feeding && !reader_done_seen;
    assign o_wbuf_free        = (state == P_IDLE) || !(rd_active && next_ready);

    assign o_chunk_start      = (state == P_PREFILL);
    assign o_chunk_word_count = cur_len;
    assign o_feed_en          = feeding;

    assign o_tile_clear       = clearing;
    assign o_acc_clear        = clearing;

    assign o_step_en          = inject || drain_advance;
    assign o_feed_valid       = inject;

    // Diagonal MAC pipeline: PE(r,c) reads pipe[r+c].
    genvar gr, gc;
    generate
        for (gr = 0; gr < `KEEP_W; gr = gr + 1) begin : g_row
            for (gc = 0; gc < `KEEP_W; gc = gc + 1) begin : g_col
                assign o_mac_valid[`KEEP_W*gr + gc] = valid_pipe[gr + gc] && row_mask_q[gr] && col_mask_q[gc];
                assign o_mac_last [`KEEP_W*gr + gc] = last_pipe [gr + gc] && row_mask_q[gr] && col_mask_q[gc];
            end
        end
    endgenerate

    // =========================================================================
    // FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= P_IDLE;
            k_left            <= K_ONE;
            c_left            <= C_ONE;
            cur_len           <= C_ONE;
            row_mask_q        <= {`KEEP_W{1'b0}};
            col_mask_q        <= {`KEEP_W{1'b0}};
            reader_done_seen  <= 1'b0;
            next_req          <= 1'b0;
            next_ready        <= 1'b0;
            tile_in_done_seen <= 1'b0;
            space_seen        <= 1'b0;
            valid_pipe        <= 5'b00000;
            last_pipe         <= 5'b00000;
        end else begin

            // Latch one-cycle completion pulses so they are not missed during drain.

            if (i_chunk_done) reader_done_seen <= 1'b1;
            if (i_tile_in_done) tile_in_done_seen <= 1'b1;
            if (i_chunk_loaded) begin           // Next chunk has arrived in the other half.
                next_req   <= 1'b0;
                next_ready <= 1'b1;
            end

            case (state)
                P_IDLE: begin
                    tile_in_done_seen <= 1'b0;
                    if (i_result_space_ready) space_seen <= 1'b1;
                    if (i_tile_valid && o_tile_ready) begin      // o_tile_ready = 1 -> now clk
                        space_seen <= 1'b0;
                        next_req   <= 1'b0;
                        next_ready <= 1'b0;
                        k_left     <= k_init;
                        c_left     <= chunk_len(k_init);
                        cur_len    <= chunk_len(k_init);
                        row_mask_q <= i_tile_row_mask;
                        col_mask_q <= i_tile_col_mask;
                        state      <= P_CLEAR;
                    end
                end

                P_CLEAR: begin
                    valid_pipe <= 5'b00000;
                    last_pipe  <= 5'b00000;
                    state      <= P_PREFILL;
                end

                P_PREFILL: begin
                    reader_done_seen <= i_chunk_done;       // new chunk -> signal LOW set
                    next_ready       <= 1'b0;
                    next_req         <= (k_left > WBUF_WORDS);
                    state            <= P_FEED;
                end

                P_FEED: begin
                    if (inject) begin
                        valid_pipe <= {valid_pipe[3:0], 1'b1};
                        last_pipe  <= {last_pipe[3:0], tile_last_beat};
                        k_left     <= k_left - 1'b1;
                        c_left     <= c_left - 1'b1;

                        if (tile_last_beat) state <= P_DRAIN;
                        else if (chunk_last_beat) state <= P_CHUNK_WAIT;
                    end
                end

                P_CHUNK_WAIT: begin     // Keep arrays as-is with step=0 while waiting for next chunk
                    if (next_ready || i_chunk_loaded) begin
                        c_left  <= chunk_len(k_left);
                        cur_len <= chunk_len(k_left);
                        state   <= P_PREFILL;
                    end
                end

                P_DRAIN: begin  // insert done but, waiting all data outs.
                    if (drain_advance) begin
                        valid_pipe <= {valid_pipe[3:0], 1'b0};
                        last_pipe  <= {last_pipe[3:0], 1'b0};
                        if (valid_pipe[3:0] == 4'b0000) state <= P_DONE;
                    end
                end

                P_DONE: begin   // pe_core stop -> out_path signal wait
                    if (i_tile_in_done || tile_in_done_seen) state <= P_IDLE;
                end

                default: state <= P_IDLE;
            endcase
        end
    end

    // synthesis translate_off
    reg [8*12-1:0] state_name;
    always @* begin
        case (state)
            P_IDLE:       state_name = "P_IDLE";
            P_CLEAR:      state_name = "P_CLEAR";
            P_PREFILL:    state_name = "P_PREFILL";
            P_FEED:       state_name = "P_FEED";
            P_CHUNK_WAIT: state_name = "P_CHUNK_WAIT";
            P_DRAIN:      state_name = "P_DRAIN";
            P_DONE:       state_name = "P_DONE";
            default:      state_name = " ";
        endcase
    end
    // synthesis translate_on
endmodule

// cnn_cntl schedules layers and tiles; pe_cntl controls PE execution.
// Weight chunks are prefetched into the opposite half of wgt_buf.

module top_cnn_cntl #(
    parameter integer NUM_LAYERS = 4,
    parameter integer WBUF_WORDS = 256,

    parameter [`ACT_AW-1:0] REGION_A_BASE = 14'd0,
    parameter [`ACT_AW-1:0] REGION_B_BASE = 14'd8192,

    parameter [   `DIM_W-1:0] L0_IN_W       = 7'd64,
    parameter [   `DIM_W-1:0] L0_IN_H       = 7'd64,
    parameter [    `CH_W-1:0] L0_IN_C       = 6'd3,
    parameter [   `DIM_W-1:0] L0_OUT_W      = 7'd64,
    parameter [   `DIM_W-1:0] L0_OUT_H      = 7'd64,
    parameter [    `CH_W-1:0] L0_OUT_C      = 6'd6,
    parameter [          1:0] L0_STRIDE     = 2'd1,
    parameter                 L0_PAD_EN     = 1'b1,
    parameter [     `K_W-1:0] L0_K          = 13'd27,
    parameter [     `K_W-1:0] L0_OUT_PIX    = 13'd4096,
    parameter [    `W_AW-1:0] L0_W_BASE     = 16'd0,
    parameter [`PARAM_AW-1:0] L0_PARAM_BASE = 7'd0,
    parameter                 L0_RELU       = 1'b1,
    parameter                 L0_POOL_EN    = 1'b1,

    parameter [   `DIM_W-1:0] L1_IN_W       = 7'd32,
    parameter [   `DIM_W-1:0] L1_IN_H       = 7'd32,
    parameter [    `CH_W-1:0] L1_IN_C       = 6'd6,
    parameter [   `DIM_W-1:0] L1_OUT_W      = 7'd32,
    parameter [   `DIM_W-1:0] L1_OUT_H      = 7'd32,
    parameter [    `CH_W-1:0] L1_OUT_C      = 6'd4,
    parameter [          1:0] L1_STRIDE     = 2'd1,
    parameter                 L1_PAD_EN     = 1'b1,
    parameter [     `K_W-1:0] L1_K          = 13'd54,
    parameter [     `K_W-1:0] L1_OUT_PIX    = 13'd1024,
    parameter [    `W_AW-1:0] L1_W_BASE     = 16'd54,
    parameter [`PARAM_AW-1:0] L1_PARAM_BASE = 7'd6,
    parameter                 L1_RELU       = 1'b1,
    parameter                 L1_POOL_EN    = 1'b0,

    parameter [   `DIM_W-1:0] L2_IN_W       = 7'd32,
    parameter [   `DIM_W-1:0] L2_IN_H       = 7'd32,
    parameter [    `CH_W-1:0] L2_IN_C       = 6'd4,
    parameter [     `K_W-1:0] L2_K          = 13'd4096,
    parameter [    `CH_W-1:0] L2_OUT_C      = 6'd32,
    parameter [    `W_AW-1:0] L2_W_BASE     = 16'd162,
    parameter [`PARAM_AW-1:0] L2_PARAM_BASE = 7'd10,
    parameter                 L2_RELU       = 1'b1,

    parameter [   `DIM_W-1:0] L3_IN_W       = 7'd1,
    parameter [   `DIM_W-1:0] L3_IN_H       = 7'd1,
    parameter [    `CH_W-1:0] L3_IN_C       = 6'd32,
    parameter [     `K_W-1:0] L3_K          = 13'd32,
    parameter [    `CH_W-1:0] L3_OUT_C      = 6'd1,
    parameter [    `W_AW-1:0] L3_W_BASE     = 16'd45218,
    parameter [`PARAM_AW-1:0] L3_PARAM_BASE = 7'd42,
    parameter                 L3_RELU       = 1'b0,

    // Per-layer requantization M/S passed unchanged to cnn_cntl.
    parameter [31:0] L0_QM = 32'd1565594,
    parameter [ 5:0] L0_QS = 6'd30,
    parameter [31:0] L1_QM = 32'd3251879,
    parameter [ 5:0] L1_QS = 6'd30,
    parameter [31:0] L2_QM = 32'd584858,
    parameter [ 5:0] L2_QS = 6'd30,
    // L3_QM/QS = Final ANGLE_MULT/ANGLE_SHIFT
    parameter [31:0] L3_QM = 32'd1281480,
    parameter [ 5:0] L3_QS = 6'd30

) (
    input wire clk,
    input wire rst_n,

    // ---- AXI4-Lite CSR (SoC) ------------------------------------------
    input  wire i_start_valid,
    output wire o_start_ready,
    output wire o_busy,

    // ---- act_ld_unit -------------------------------------------------------
    output wire o_img_ld_start,
    input  wire i_ld_done,
    output wire o_writer_mode,

    // ---- act_patch_gen / fc_gen : Layer descriptor ------------------------
    output wire               o_layer_cfg_valid,
    output wire [`ACT_AW-1:0] o_src_base,
    output wire [ `DIM_W-1:0] o_in_w,
    output wire [ `DIM_W-1:0] o_in_h,
    output wire [  `CH_W-1:0] o_in_c,
    output wire [        1:0] o_stride,
    output wire               o_pad_en,
    output wire [   `K_W-1:0] o_k_total,
    output wire               o_path_sel,

    // ---- Tile Setting ----------------------------------------------------------
    output wire               o_pg_tile_start,
    output wire               o_fc_tile_start,
    output wire [       13:0] o_pos_base,
    output wire [`KEEP_W-1:0] o_row_mask,
    output wire [`KEEP_W-1:0] o_col_mask,
    output wire               o_tile_cfg_valid,
    output wire [ `OCB_W-1:0] o_out_ch_base,
    output wire               o_tile_last,
    output wire               o_relu_en,
    output wire [        5:0] o_param_base,
    input  wire               i_params_ready,

    // ---- Layer output path ---------------------------------------------------
    output wire               o_output_cfg_valid,
    output wire [`ACT_AW-1:0] o_dst_base,
    output wire [  `CH_W-1:0] o_out_c,
    output wire [ `DIM_W-1:0] o_pool_in_w,
    output wire [ `DIM_W-1:0] o_pool_in_h,
    output wire [  `CH_W-1:0] o_pool_c,
    output wire               o_pool_en,
    output wire               o_is_final_layer,

    // ---- wgt_ld_unit -------------------------------------------------------
    output wire                o_wload_start,
    input  wire                i_wload_ready,
    output wire [        15:0] o_mem_base,
    output wire [`CHUNK_W-1:0] o_load_chunk_len,
    output wire                o_buf_half,
    input  wire                i_wload_done,
    output wire                o_wbuf_free,

    // ---- wgt_patch_gen -----------------------------------------------------
    output wire                o_reader_start,
    output wire [`CHUNK_W-1:0] o_reader_chunk_len,
    input  wire                i_reader_done,

    // ---- Feeder ------------------------------------------------------------
    output wire [`KEEP_W-1:0] o_pe_col_mask,
    output wire               o_feeder_en,
    output wire               o_tile_clear,
    input  wire               i_weight_valid,
    input  wire               i_act_valid,

    // ---- pe_core -----------------------------------------------------------
    output wire             o_step_en,
    output wire             o_feed_valid,
    output wire             o_acc_clear,
    output wire [`PE_N-1:0] o_mac_valid,
    output wire [`PE_N-1:0] o_mac_last,

    // ---- output_fifo -------------------------------------------------------
    input wire i_result_space_ready,

    // ---- RAM (Read Parameter) ---------------------------------------------
    output wire                 o_ram_owner,
    output wire [`PARAM_AW-1:0] o_param_mem_addr,
    input  wire [         31:0] i_param_mem_data,

    // ---- param_buf ---------------------------------------------------------
    output wire        o_param_wr_en,
    output wire [ 5:0] o_param_wr_addr,
    output wire [31:0] o_param_wr_data,
    output wire        o_param_load_start,
    input  wire        i_param_load_done,
    output wire [31:0] o_quant_multiplier,
    output wire [ 5:0] o_quant_shift,

    // ---- Done signal --------------------------------------------------------------
    input wire i_tile_in_done,
    input wire i_layer_done,
    input wire i_done_status,

    // ---- Debugging ------------------------------------------------------------
    output wire [2:0] o_layer_idx,
    output wire [3:0] o_cnn_state,
    output wire       o_pe_cmd_ready_dbg
);

    wire pe_cmd_valid, pe_cmd_ready;
    wire [`K_W-1:0] pe_step_total;
    wire [`KEEP_W-1:0] pe_row_mask, pe_col_mask;

    // Adapt internal controller signal names to the datapath interface.

    // Adapt controller field widths to the external datapath ports.
    wire [`POS_W-1:0] pos_base_12;
    wire [ `W_AW-1:0] mem_base_16;
    wire [`PARAM_AW-1:0] param_base_7, param_wr_addr_7;
    assign o_pos_base         = {2'b00, pos_base_12};
    assign o_mem_base         = mem_base_16;
    assign o_param_base       = param_base_7[5:0];
    assign o_param_wr_addr    = param_wr_addr_7[5:0];

    assign o_pe_col_mask      = o_col_mask;
    assign o_output_cfg_valid = o_layer_cfg_valid;
    assign o_pool_c           = o_out_c;

    wire chunk_req, chunk_loaded;
    assign o_pe_cmd_ready_dbg = pe_cmd_ready;

    cnn_cntl #(
        .NUM_LAYERS(NUM_LAYERS),
        .WBUF_WORDS(WBUF_WORDS),
        .REGION_A_BASE(REGION_A_BASE),
        .REGION_B_BASE(REGION_B_BASE),
        .L0_IN_W(L0_IN_W),
        .L0_IN_H(L0_IN_H),
        .L0_IN_C(L0_IN_C),
        .L0_OUT_W(L0_OUT_W),
        .L0_OUT_H(L0_OUT_H),
        .L0_OUT_C(L0_OUT_C),
        .L0_STRIDE(L0_STRIDE),
        .L0_PAD_EN(L0_PAD_EN),
        .L0_K(L0_K),
        .L0_OUT_PIX(L0_OUT_PIX),
        .L0_W_BASE(L0_W_BASE),
        .L0_PARAM_BASE(L0_PARAM_BASE),
        .L0_RELU(L0_RELU),
        .L0_POOL_EN(L0_POOL_EN),
        .L1_IN_W(L1_IN_W),
        .L1_IN_H(L1_IN_H),
        .L1_IN_C(L1_IN_C),
        .L1_OUT_W(L1_OUT_W),
        .L1_OUT_H(L1_OUT_H),
        .L1_OUT_C(L1_OUT_C),
        .L1_STRIDE(L1_STRIDE),
        .L1_PAD_EN(L1_PAD_EN),
        .L1_K(L1_K),
        .L1_OUT_PIX(L1_OUT_PIX),
        .L1_W_BASE(L1_W_BASE),
        .L1_PARAM_BASE(L1_PARAM_BASE),
        .L1_RELU(L1_RELU),
        .L1_POOL_EN(L1_POOL_EN),
        .L2_IN_W(L2_IN_W),
        .L2_IN_H(L2_IN_H),
        .L2_IN_C(L2_IN_C),
        .L2_K(L2_K),
        .L2_OUT_C(L2_OUT_C),
        .L2_W_BASE(L2_W_BASE),
        .L2_PARAM_BASE(L2_PARAM_BASE),
        .L2_RELU(L2_RELU),
        .L3_IN_W(L3_IN_W),
        .L3_IN_H(L3_IN_H),
        .L3_IN_C(L3_IN_C),
        .L3_K(L3_K),
        .L3_OUT_C(L3_OUT_C),
        .L3_W_BASE(L3_W_BASE),
        .L3_PARAM_BASE(L3_PARAM_BASE),
        .L3_RELU(L3_RELU),
        .L0_QM(L0_QM),
        .L0_QS(L0_QS),
        .L1_QM(L1_QM),
        .L1_QS(L1_QS),
        .L2_QM(L2_QM),
        .L2_QS(L2_QS),
        .L3_QM(L3_QM),
        .L3_QS(L3_QS)
    ) U_CNN_CNTL (
        .clk(clk),
        .rst_n(rst_n),
        .i_start_valid(i_start_valid),
        .o_start_ready(o_start_ready),
        .o_busy(o_busy),
        .o_ld_start(o_img_ld_start),
        .i_ld_done(i_ld_done),
        .o_write_grant(o_writer_mode),
        .o_layer_cfg_valid(o_layer_cfg_valid),
        .o_src_base(o_src_base),
        .o_in_w(o_in_w),
        .o_in_h(o_in_h),
        .o_in_c(o_in_c),
        .o_stride(o_stride),
        .o_pad_en(o_pad_en),
        .o_k_total(o_k_total),
        .o_fc_mode(o_path_sel),
        .o_pg_tile_start(o_pg_tile_start),
        .o_fc_tile_start(o_fc_tile_start),
        .o_pos_base(pos_base_12),
        .o_row_mask(o_row_mask),
        .o_col_mask(o_col_mask),
        .o_tile_cfg_valid(o_tile_cfg_valid),
        .o_out_ch_base(o_out_ch_base),
        .o_tile_last(o_tile_last),
        .o_relu_en(o_relu_en),
        .o_bias_base(param_base_7),
        .i_params_ready(i_params_ready),
        .o_dst_base(o_dst_base),
        .o_out_channels(o_out_c),
        .o_conv_w(o_pool_in_w),
        .o_conv_h(o_pool_in_h),
        .o_pool_en(o_pool_en),
        .o_is_final_layer(o_is_final_layer),
        .o_tile_valid(pe_cmd_valid),
        .i_tile_ready(pe_cmd_ready),
        .o_step_total(pe_step_total),
        .o_tile_row_mask(pe_row_mask),
        .o_tile_col_mask(pe_col_mask),
        .i_chunk_req(chunk_req),
        .o_chunk_loaded(chunk_loaded),
        .o_wload_start(o_wload_start),
        .i_wload_ready(i_wload_ready),
        .o_mem_base(mem_base_16),
        .o_chunk_word_count(o_load_chunk_len),
        .o_buf_half(o_buf_half),
        .i_wload_done(i_wload_done),
        .o_ram_owner(o_ram_owner),
        .o_param_mem_addr(o_param_mem_addr),
        .i_param_mem_data(i_param_mem_data),
        .o_param_wr_en(o_param_wr_en),
        .o_param_wr_addr(param_wr_addr_7),
        .o_param_wr_data(o_param_wr_data),
        .o_quant_multiplier(o_quant_multiplier),
        .o_quant_shift(o_quant_shift),
        .o_param_load_start(o_param_load_start),
        .i_param_load_done(i_param_load_done),
        .i_tile_in_done(i_tile_in_done),
        .i_layer_done(i_layer_done),
        .i_done_status(i_done_status),
        .o_layer_idx(o_layer_idx),
        .o_state(o_cnn_state)
    );

    pe_cntl #(
        .WBUF_WORDS(WBUF_WORDS)
    ) U_PE_CNTL (
        .clk(clk),
        .rst_n(rst_n),
        .i_tile_valid(pe_cmd_valid),
        .o_tile_ready(pe_cmd_ready),
        .i_step_total(pe_step_total),
        .i_tile_row_mask(pe_row_mask),
        .i_tile_col_mask(pe_col_mask),
        .o_chunk_req(chunk_req),
        .i_chunk_loaded(chunk_loaded),
        .o_wbuf_free(o_wbuf_free),
        .o_chunk_start(o_reader_start),
        .o_chunk_word_count(o_reader_chunk_len),
        .i_chunk_done(i_reader_done),
        .o_feed_en(o_feeder_en),
        .o_tile_clear(o_tile_clear),
        .i_weight_valid(i_weight_valid),
        .i_act_valid(i_act_valid),
        .o_step_en(o_step_en),
        .o_feed_valid(o_feed_valid),
        .o_acc_clear(o_acc_clear),
        .o_mac_valid(o_mac_valid),
        .o_mac_last(o_mac_last),
        .i_result_space_ready(i_result_space_ready),
        .i_tile_in_done(i_tile_in_done)
    );

    // synthesis translate_off
    function [8*12-1:0] ljust12;
        input [8*12-1:0] s;
        integer i;
        begin
            ljust12 = s;
            for (i = 0; i < 12; i = i + 1)
            if (ljust12[8*12-1-:8] == 8'h00) ljust12 = {ljust12[8*11-1:0], " "};
        end
    endfunction

    wire [8*12-1:0] cnn_state_name = U_CNN_CNTL.state_name;
    wire [ 8*8-1:0] wsvc_name = U_CNN_CNTL.wsvc_name;
    wire [8*16-1:0] tile_name = U_CNN_CNTL.tile_name;
    wire [8*12-1:0] pe_state_name = U_PE_CNTL.state_name;

    reg  [8*27-1:0] ctrl_state_name;
    always @*
        ctrl_state_name = {
            ljust12(cnn_state_name), " / ", ljust12(pe_state_name)
        };
    // synthesis translate_on
endmodule
