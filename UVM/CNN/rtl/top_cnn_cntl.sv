`timescale 1ns / 1ps
`include "cnn_defs.vh"

// ---- cnn_cntl ----
// Layer/tile sequencer: walks layers and tiles, loads weight chunks and Bias records.
module cnn_cntl #(
    parameter integer NUM_LAYERS = 4,                       // Conv0, Conv1, fc1, fc2
    parameter integer WBUF_WORDS = 256,                     // one wgt_buf half = max chunk length

    // input_buf split into two regions; read/write regions swap each layer.
    parameter [`ACT_AW-1:0] REGION_A_BASE = 14'd0,          // image, Conv1 output
    parameter [`ACT_AW-1:0] REGION_B_BASE = 14'd8192,       // Conv0+Pool output, fc1 output

    parameter [31:0] IMG_RAM_BASE = 32'd0,                  // image start Word in RAM

    // ---- Layer 0 : Conv0 3x3 3->6, S=1, P=1, ReLU, MaxPool ----
    parameter [`DIM_W-1:0]      L0_IN_W       = 7'd64,
    parameter [`DIM_W-1:0]      L0_IN_H       = 7'd64,
    parameter [`CH_W-1:0]       L0_IN_C       = 6'd3,
    parameter [`DIM_W-1:0]      L0_OUT_W      = 7'd64,        // size before Pool
    parameter [`DIM_W-1:0]      L0_OUT_H      = 7'd64,
    parameter [`CH_W-1:0]       L0_OUT_C      = 6'd6,
    parameter [1:0]             L0_STRIDE     = 2'd1,
    parameter                   L0_PAD_EN     = 1'b1,
    parameter [`K_W-1:0]        L0_K          = 13'd27,       // 3 x 3 x 3
    parameter [`K_W-1:0]        L0_OUT_PIX    = 13'd4096,     // 64 x 64
    parameter [`W_AW-1:0]       L0_W_BASE     = 16'd0,        // uses 54 Words
    parameter [`PARAM_AW-1:0]   L0_PARAM_BASE = 7'd0,         // 6 records
    parameter                   L0_RELU       = 1'b1,
    parameter                   L0_POOL_EN    = 1'b1,         // 2x2 MaxPool -> 32x32x6

    // ---- Layer 1 : Conv1 3x3 6->4, S=1, P=1, ReLU ----
    parameter [`DIM_W-1:0]      L1_IN_W         = 7'd32,
    parameter [`DIM_W-1:0]      L1_IN_H         = 7'd32,
    parameter [`CH_W-1:0]       L1_IN_C         = 6'd6,         // 2 Words per pixel
    parameter [`DIM_W-1:0]      L1_OUT_W        = 7'd32,
    parameter [`DIM_W-1:0]      L1_OUT_H        = 7'd32,
    parameter [`CH_W-1:0]       L1_OUT_C        = 6'd4,
    parameter [1:0]             L1_STRIDE       = 2'd1,
    parameter                   L1_PAD_EN       = 1'b1,
    parameter [`K_W-1:0]        L1_K            = 13'd54,       // 3 x 3 x 6
    parameter [`K_W-1:0]        L1_OUT_PIX      = 13'd1024,     // 32 x 32
    parameter [`W_AW-1:0]       L1_W_BASE       = 16'd54,       // uses 108 Words
    parameter [`PARAM_AW-1:0]   L1_PARAM_BASE   = 7'd6,         // 4 records
    parameter                   L1_RELU         = 1'b1,
    parameter                   L1_POOL_EN      = 1'b0,

    // ---- Layer 2 : fc1  4096 -> 32, ReLU ----
    // in_c needed so fc_gen can skip per-pixel padding lanes.
    parameter [`DIM_W-1:0]      L2_IN_W         = 7'd32,
    parameter [`DIM_W-1:0]      L2_IN_H         = 7'd32,
    parameter [`CH_W-1:0]       L2_IN_C         = 6'd4,
    parameter [`K_W-1:0]        L2_K            = 13'd4096,             // 16 chunks of 256 Words
    parameter [`CH_W-1:0]       L2_OUT_C        = 6'd32,
    parameter [`W_AW-1:0]       L2_W_BASE       = 16'd162,              // uses 45,056 Words
    parameter [`PARAM_AW-1:0]   L2_PARAM_BASE   = 7'd10,                // 32 records
    parameter                   L2_RELU         = 1'b1,

    // ---- Layer 3 : fc2  32 -> 1, final regression ----
    parameter [`DIM_W-1:0]      L3_IN_W         = 7'd1,
    parameter [`DIM_W-1:0]      L3_IN_H         = 7'd1,
    parameter [`CH_W-1:0]       L3_IN_C         = 6'd32,
    parameter [`K_W-1:0]        L3_K            = 13'd32,
    parameter [`CH_W-1:0]       L3_OUT_C        = 6'd1,
    parameter [`W_AW-1:0]       L3_W_BASE       = 16'd45218,            // uses 32 Words
    parameter [`PARAM_AW-1:0]   L3_PARAM_BASE   = 7'd42,                // 1 record (43 total)
    parameter                   L3_RELU         = 1'b0,

    // ---- per layer Requant M / S ----
    // q = sat_int8(round((acc + bias) * M / 2^S)), S in 0..30; L3 LSB = 1 degree.
    parameter [31:0] L0_QM = 32'd1463994,
    parameter [ 5:0] L0_QS = 6'd30,
    parameter [31:0] L1_QM = 32'd4487009,
    parameter [ 5:0] L1_QS = 6'd30,
    parameter [31:0] L2_QM = 32'd849386,
    parameter [ 5:0] L2_QS = 6'd30,
    parameter [31:0] L3_QM = 32'd1046256,
    parameter [ 5:0] L3_QS = 6'd30
) (
    input logic clk,
    input logic rst_n,

    // ---- AXI4-Lite CSR / RAM ----
    input  logic                    i_start_valid,
    output logic                    o_start_ready,          // 1 only when IDLE and !done_status
    output logic                    o_busy,
    output logic                    o_ram_owner,            // 0=weight, 1=param
    output logic [`PARAM_AW-1:0]    o_param_mem_addr,       // record number 0..42
    input  logic [31:0]             i_param_mem_data,       // signed INT32 Bias

    // ---- pe_cntl : tile cmd ----
    output logic                 o_tile_valid,
    input  logic                 i_tile_ready,
    output logic [`K_W-1:0]      o_step_total,           // MAC steps per tile = K
    output logic [`KEEP_W-1:0]   o_tile_row_mask,
    output logic [`KEEP_W-1:0]   o_tile_col_mask,

    // ---- pe_cntl : chunk reload (K > 256 only) ----
    // pe_cntl only requests; cnn_cntl tracks k_base and length.
    input  logic                 i_chunk_req,            // level, held until o_chunk_loaded
    output logic                 o_chunk_loaded,         // 1clk pulse

    // ---- act_ld_unit ----
    output logic                 o_ld_start,             // 1clk pulse
    output logic [31:0]          o_ram_base,             // = IMG_RAM_BASE
    output logic [`K_W-1:0]      o_ld_word_count,        // image Words (4096)
    input  logic                 i_ld_done,              // 1clk pulse
    output logic                 o_write_grant,          // 0 = image load, 1 = result write

    // ---- act_patch_gen / fc_gen / MUX : layer descriptor ----
    output logic                 o_layer_cfg_valid,      // 1clk pulse
    output logic [`ACT_AW-1:0]   o_src_base,
    output logic [`DIM_W-1:0]    o_in_w,
    output logic [`DIM_W-1:0]    o_in_h,
    output logic [`CH_W-1:0]     o_in_c,
    output logic [1:0]           o_stride,
    output logic                 o_pad_en,
    output logic [`K_W-1:0]      o_k_total,
    output logic [`K_W-1:0]      o_fc_in_count,          // = o_k_total
    output logic                 o_fc_mode,              // 0=Conv, 1=FC

    // ---- act_patch_gen / fc_gen : tile ----
    output logic                 o_pg_tile_start,
    output logic                 o_fc_tile_start,
    output logic [`POS_W-1:0]    o_pos_base,             // first patch index (2x2 Z order)
    output logic [`KEEP_W-1:0]   o_row_mask,

    // ---- wgt_ld_unit / wgt_patch_gen ----
    output logic                 o_wload_start,          // 1clk pulse, only when i_wload_ready
    input  logic                 i_wload_ready,
    output logic [`W_AW-1:0]     o_mem_base,             // W_BASE + oc_group*K + k_base
    output logic [`CHUNK_W-1:0]  o_chunk_word_count,     // 1..256
    output logic                 o_buf_half,             // target wgt_buf half
    input  logic                 i_wload_done,           // 1clk pulse

    // ---- out_path ----
    output logic                 o_tile_cfg_valid,       // 1clk pulse, only when i_tile_ready
    output logic                 o_is_fc,
    output logic                 o_is_final_layer,
    output logic                 o_pool_en,
    output logic [`DIM_W-1:0]    o_conv_w,               // width before Pool
    output logic [`DIM_W-1:0]    o_conv_h,               // height before Pool
    output logic [`CH_W-1:0]     o_out_channels,
    output logic [`ACT_AW-1:0]   o_dst_base,
    output logic                 o_relu_en,
    output logic [31:0]          o_quant_multiplier,     // layer M
    output logic [5:0]           o_quant_shift,          // layer S (0..30)
    output logic [`PARAM_AW-1:0] o_bias_base,            // first record of layer
    output logic [`POS_W-1:0]    o_patch_base,           // = o_pos_base
    output logic [`OCB_W-1:0]    o_out_ch_base,
    output logic [`KEEP_W-1:0]   o_col_mask,             // fixed during a tile
    output logic                 o_tile_last,
    output logic                 o_param_load_start,     // 1clk pulse
    input  logic                 i_param_load_done,      // 1clk pulse after 43rd Bias
    input  logic                 i_params_ready,
    output logic                 o_param_wr_en,
    output logic [`PARAM_AW-1:0] o_param_wr_addr,
    output logic [31:0]          o_param_wr_data,        // signed INT32 Bias
    input  logic                 i_tile_in_done,
    input  logic                 i_layer_done,
    input  logic                 i_done_status,

    // ---- Debug ----
    output logic [2:0]           o_layer_idx,
    output logic [3:0]           o_state
);

    // ---- FSM ----
    typedef enum logic [3:0] {
        C_IDLE       = 4'd0,
        C_START      = 4'd1,
        C_PARAM_LOAD = 4'd2,   // once per inference
        C_SET        = 4'd3,   // once per layer
        C_W_LOAD     = 4'd4,   // from here on, once per tile
        C_TILE_CFG   = 4'd5,
        C_PE_TILE    = 4'd6,
        C_PE_WAIT    = 4'd7,
        C_NXT_TILE   = 4'd8,
        C_LAYER_END  = 4'd9,
        C_DONE       = 4'd10
    } c_state_e;

    c_state_e   state;
    logic [2:0] layer_idx;
    logic       region_sel; // 0: read A/write B, 1: read B/write A

    // Tile coordinates
    logic [`POS_W-1:0] pos_group;      // group of 3 output positions
    logic [`OCG_W-1:0] oc_group;       // group of 3 output channels
    logic [`W_AW-1:0]  og_off_q;       // oc_group * K, accumulated (no multiplier)

    logic tile_started;
    logic tcfg_sent;
    logic first_chunk_rdy;
    logic tile_in_done_seen;
    logic layer_done_seen;
    logic ld_done_seen;

    assign o_busy        = (state != C_IDLE);
    assign o_layer_idx   = layer_idx;
    assign o_state       = state;
    assign o_start_ready = (state == C_IDLE) && !i_done_status;

    // ---- Layer config select ----
    logic [`DIM_W-1:0] ly_in_w, ly_in_h, ly_out_w, ly_out_h;
    logic [`CH_W-1:0] ly_in_c, ly_out_c;
    logic [1:0] ly_stride;
    logic       ly_pad_en;
    logic [`K_W-1:0] ly_k, ly_out_pix;
    logic [    `W_AW-1:0] ly_w_base;
    logic [`PARAM_AW-1:0] ly_param_base;
    logic ly_relu, ly_pool_en, ly_is_fc;
    logic [31:0] ly_qm;
    logic [ 5:0] ly_qs;

    always_comb begin
        ly_in_w = 7'd1; ly_in_h = 7'd1; ly_in_c = 6'd1;
        ly_out_w = 7'd1; ly_out_h = 7'd1; ly_out_c = 6'd1;
        ly_stride = 2'd1; ly_pad_en = 1'b0; ly_k = 13'd1;
        ly_out_pix = 13'd1;
        ly_w_base = {`W_AW{1'b0}}; ly_param_base = {`PARAM_AW{1'b0}};
        ly_relu = 1'b0; ly_pool_en = 1'b0;
        ly_is_fc = 1'b1;
        ly_qm = 32'h4000_0000; ly_qs = 6'd30;

        case (layer_idx)
            3'd0: begin                                    // Conv0
                ly_in_w = L0_IN_W; ly_in_h = L0_IN_H; ly_in_c = L0_IN_C;
                ly_out_w = L0_OUT_W; ly_out_h = L0_OUT_H; ly_out_c = L0_OUT_C;
                ly_stride = L0_STRIDE; ly_pad_en = L0_PAD_EN; ly_k = L0_K;
                ly_out_pix = L0_OUT_PIX;
                ly_w_base = L0_W_BASE; ly_param_base = L0_PARAM_BASE;
                ly_relu = L0_RELU; ly_pool_en = L0_POOL_EN;
                ly_is_fc = 1'b0;
                ly_qm = L0_QM; ly_qs = L0_QS;
            end
            3'd1: begin                                    // Conv1
                ly_in_w = L1_IN_W; ly_in_h = L1_IN_H; ly_in_c = L1_IN_C;
                ly_out_w = L1_OUT_W; ly_out_h = L1_OUT_H; ly_out_c = L1_OUT_C;
                ly_stride = L1_STRIDE; ly_pad_en = L1_PAD_EN;
                ly_k = L1_K;
                ly_out_pix = L1_OUT_PIX;
                ly_w_base = L1_W_BASE; ly_param_base = L1_PARAM_BASE;
                ly_relu = L1_RELU; ly_pool_en = L1_POOL_EN;
                ly_is_fc = 1'b0;
                ly_qm = L1_QM; ly_qs = L1_QS;
            end
            3'd2: begin                                    // fc1
                ly_in_w = L2_IN_W; ly_in_h = L2_IN_H; ly_in_c = L2_IN_C;
                ly_out_w = 7'd1; ly_out_h = 7'd1; ly_out_c = L2_OUT_C;
                ly_k = L2_K;
                ly_out_pix = 13'd1;
                ly_w_base = L2_W_BASE; ly_param_base = L2_PARAM_BASE;
                ly_relu = L2_RELU;
                ly_is_fc = 1'b1;
                ly_qm = L2_QM; ly_qs = L2_QS;
            end
            default: begin                                 // fc2
                ly_in_w = L3_IN_W; ly_in_h = L3_IN_H; ly_in_c = L3_IN_C;
                ly_out_w = 7'd1; ly_out_h = 7'd1; ly_out_c = L3_OUT_C;
                ly_k = L3_K;
                ly_out_pix = 13'd1;
                ly_w_base = L3_W_BASE; ly_param_base = L3_PARAM_BASE;
                ly_relu = L3_RELU;
                ly_is_fc = 1'b1;
                ly_qm = L3_QM; ly_qs = L3_QS;
            end
        endcase
    end

    assign o_in_w               = ly_in_w;
    assign o_in_h               = ly_in_h;
    assign o_in_c               = ly_in_c;
    assign o_out_channels       = ly_out_c;
    assign o_stride             = ly_stride;
    assign o_pad_en             = ly_pad_en;
    assign o_k_total            = ly_k;
    assign o_relu_en            = ly_relu;
    assign o_pool_en            = ly_pool_en;
    assign o_quant_multiplier   = ly_qm;
    assign o_quant_shift        = ly_qs;
    assign o_bias_base          = ly_param_base;
    assign o_fc_mode            = ly_is_fc;
    assign o_is_fc              = ly_is_fc;
    assign o_is_final_layer     = (layer_idx == (NUM_LAYERS - 1));

    // pooling_unit gets the size before Pool
    assign o_conv_w = ly_out_w;
    assign o_conv_h = ly_out_h;

    localparam [`K_W-1:0] IMG_WORDS = L0_IN_W * L0_IN_H * ((L0_IN_C + 2) / 3);      // W * H * ceil(C/3)
    assign o_ram_base               = IMG_RAM_BASE;
    assign o_ld_word_count          = IMG_WORDS;
    assign o_fc_in_count            = ly_k;
    assign o_step_total             = ly_k;
    assign o_tile_row_mask          = o_row_mask;
    assign o_tile_col_mask          = o_col_mask;
    assign o_patch_base             = o_pos_base;

    // Region swap: image in A; L0 A->B, L1 B->A, L2 A->B, L3 reads B.
    assign o_src_base = region_sel ? REGION_B_BASE : REGION_A_BASE;
    assign o_dst_base = region_sel ? REGION_A_BASE : REGION_B_BASE;

    // ---- Tile decode ----
    function automatic logic [2:0] lane_mask(input logic [`K_W-1:0] total, input logic [`K_W-1:0] base);
        logic [`K_W-1:0] remain;
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

    logic [`K_W-1:0] pos_base_k;
    assign pos_base_k = {{(`K_W - `POS_W) {1'b0}}, pos_group} * 13'd3;
    logic [`K_W-1:0] oc_base_k;
    assign oc_base_k = {{(`K_W - `OCG_W) {1'b0}}, oc_group} * 13'd3;
    logic [`K_W-1:0] out_c_k;
    assign out_c_k = {{(`K_W - `CH_W) {1'b0}}, ly_out_c};

    // Patch index (2x2 Z order), not a raster position.
    assign o_pos_base    = pos_base_k[`POS_W-1:0];
    assign o_out_ch_base = oc_base_k[`OCB_W-1:0];
    // Registered masks for timing; safe since consumers sample >= 2clk after C_NXT_TILE.
    logic [`KEEP_W-1:0] row_mask_r, col_mask_r;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_mask_r <= {`KEEP_W{1'b0}};
            col_mask_r <= {`KEEP_W{1'b0}};
        end else begin
            row_mask_r <= lane_mask(ly_out_pix, pos_base_k);
            col_mask_r <= lane_mask(out_c_k,    oc_base_k);
        end
    end
    assign o_row_mask    = row_mask_r;
    assign o_col_mask    = col_mask_r;

    logic pos_last;
    assign pos_last = ((pos_base_k + 13'd3) >= ly_out_pix);
    logic oc_last;
    assign oc_last = ((oc_base_k + 13'd3) >= out_c_k);
    assign o_tile_last = pos_last && oc_last;

    // ---- Weight load service ----
    // Serves both the first chunk (C_W_LOAD) and mid-tile chunks (C_PE_WAIT).
    typedef enum logic [1:0] {
        W_IDLE  = 2'd0,
        W_ISSUE = 2'd1,
        W_WAIT  = 2'd2,
        W_REPLY = 2'd3
    } w_state_e;

    w_state_e wsvc;
    logic [`K_W-1:0] svc_kbase;
    logic [`CHUNK_W-1:0] svc_len;

    // K <= WBUF_WORDS: half = oc_group parity, tagged (layer, oc_group) to skip reloads.
    // Larger K: chunk 0 in half 0, then alternate halves (preload next while reading).
    logic              buf_half;
    logic              wtag_valid [0:1];
    logic [2:0]        wtag_layer [0:1];
    logic [`OCG_W-1:0] wtag_oc    [0:1];
    logic first_half;
    assign first_half = (ly_k > WBUF_WORDS) ? 1'b0 : oc_group[0];   // half of the tile's first chunk
    logic wload_skip;
    assign wload_skip = wtag_valid[first_half] && (wtag_layer[first_half] == layer_idx) &&
                      (wtag_oc[first_half] == oc_group) && (ly_k <= WBUF_WORDS);

    // min(remain, WBUF_WORDS)
    function automatic logic [`CHUNK_W-1:0] chunk_len(input logic [`K_W-1:0] remain);
        begin
            chunk_len = (remain > WBUF_WORDS) ? WBUF_WORDS[`CHUNK_W-1:0] : remain[`CHUNK_W-1:0];
        end
    endfunction

    logic [`CHUNK_W-1:0] first_len;
    assign first_len = chunk_len(
        ly_k
    );

    // next chunk within a tile
    logic [`K_W-1:0]     nx_kbase;
    assign nx_kbase = svc_kbase + {{(`K_W-`CHUNK_W){1'b0}}, svc_len};
    logic [`CHUNK_W-1:0] nx_len;
    assign nx_len = chunk_len(ly_k - nx_kbase);

    logic chunk_accept;
    assign chunk_accept = (state == C_PE_WAIT) && (wsvc == W_IDLE) && i_chunk_req;

    // mem_base = W_BASE + oc_group*K + k_base; max 45,249 fits in 16 bits.
    logic [`W_AW-1:0] og_ext;
    assign og_ext = {{(`W_AW - `OCG_W) {1'b0}}, oc_group};
    logic [`W_AW-1:0] k_ext;
    assign k_ext = {{(`W_AW - `K_W) {1'b0}}, ly_k};
    logic [`W_AW-1:0] kb_ext;
    assign kb_ext = {{(`W_AW - `K_W) {1'b0}}, svc_kbase};
    logic [`W_AW-1:0] og_off;
    assign og_off = og_off_q;
    assign o_mem_base         = ly_w_base + og_off + kb_ext;

    // W_ISSUE waits for ready; start pulses on that clk.
    assign o_wload_start      = (wsvc == W_ISSUE) && i_wload_ready;
    assign o_chunk_word_count = svc_len;
    assign o_chunk_loaded     = (wsvc == W_REPLY);  // W_REPLY lasts 1clk
    assign o_buf_half         = buf_half;

    // ---- Param RAM -> param_buf bulk load (once per inference) ----
    // Records packed in layer order. Fixed 1clk read latency, 2clk per record.
    localparam [`PARAM_AW:0] PARAM_TOTAL =
          (NUM_LAYERS <= 1) ? (L0_PARAM_BASE + L0_OUT_C) :
          (NUM_LAYERS == 2) ? (L1_PARAM_BASE + L1_OUT_C) :
          (NUM_LAYERS == 3) ? (L2_PARAM_BASE + L2_OUT_C) :
                              (L3_PARAM_BASE + L3_OUT_C);

    logic [`PARAM_AW:0] pl_idx;  // 0 .. PARAM_TOTAL (1bit headroom)
    logic pl_busy;
    logic pl_done;
    logic [`PARAM_AW-1:0] pl_addr_q;

    logic pl_more;
    assign pl_more = (pl_idx < PARAM_TOTAL);

    assign o_ram_owner = (state == C_PARAM_LOAD);

    assign o_param_mem_addr = pl_idx[`PARAM_AW-1:0];

    logic pmem_req_fire;
    assign pmem_req_fire = (state == C_PARAM_LOAD) && pl_more && !pl_busy;   // read issued
    logic pmem_rsp_fire;
    assign pmem_rsp_fire = pl_busy;                                            // data from previous clk's address

    assign o_param_wr_en = pmem_rsp_fire;
    assign o_param_wr_addr = pl_addr_q;
    assign o_param_wr_data = i_param_mem_data;

    assign o_tile_valid = (state == C_PE_TILE) && tile_started;

    // 1clk on first i_tile_ready in C_TILE_CFG; tcfg_sent prevents a repeat.
    assign o_tile_cfg_valid = (state == C_TILE_CFG) && !tcfg_sent && i_tile_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= C_IDLE;
            layer_idx <= 3'd0;
            region_sel <= 1'b0;
            pos_group         <= {`POS_W{1'b0}};
            oc_group          <= {`OCG_W{1'b0}};
            og_off_q          <= {`W_AW{1'b0}};
            tile_started <= 1'b0;
            tcfg_sent <= 1'b0;
            first_chunk_rdy <= 1'b0;
            tile_in_done_seen <= 1'b0;
            layer_done_seen <= 1'b0;
            o_ld_start <= 1'b0;
            o_param_load_start <= 1'b0;
            ld_done_seen <= 1'b0;
            o_write_grant <= 1'b0;
            o_layer_cfg_valid <= 1'b0;
            o_pg_tile_start <= 1'b0;
            o_fc_tile_start <= 1'b0;
            wsvc <= W_IDLE;
            svc_kbase         <= {`K_W{1'b0}};
            svc_len           <= {`CHUNK_W{1'b0}};
            buf_half          <= 1'b0;
            wtag_valid[0] <= 1'b0;  wtag_valid[1] <= 1'b0;
            wtag_layer[0] <= 3'd0;  wtag_layer[1] <= 3'd0;
            wtag_oc[0]        <= {`OCG_W{1'b0}};
            wtag_oc[1]        <= {`OCG_W{1'b0}};
            pl_idx            <= {(`PARAM_AW+1){1'b0}};
            pl_busy <= 1'b0;
            pl_done <= 1'b0;
            pl_addr_q         <= {`PARAM_AW{1'b0}};
        end else begin
            o_ld_start    <= 1'b0;
            o_param_load_start <= 1'b0;
            o_layer_cfg_valid <= 1'b0;
            o_pg_tile_start   <= 1'b0;
            o_fc_tile_start   <= 1'b0;

            if (i_tile_in_done) tile_in_done_seen <= 1'b1;
            if (i_layer_done)   layer_done_seen <= 1'b1;
            if (i_ld_done)      ld_done_seen <= 1'b1;

            // ---- Weight load ----
            case (wsvc)
                W_IDLE: begin
                    if (chunk_accept) begin
                        svc_kbase <= nx_kbase;
                        svc_len   <= nx_len;
                        buf_half  <= ~buf_half;                 // load into the half not being read
                        wsvc      <= W_ISSUE;
                    end
                end
                W_ISSUE: if (i_wload_ready) wsvc <= W_WAIT;
                W_WAIT:
                if (i_wload_done) begin
                    if (state == C_PE_WAIT) begin           // mid-tile chunk
                        wtag_valid[buf_half] <= 1'b0;       // tag invalid: half overwritten
                        wsvc <= W_REPLY;
                    end else begin
                        first_chunk_rdy      <= 1'b1;
                        wtag_valid[buf_half] <= 1'b1;
                        wtag_layer[buf_half] <= layer_idx;
                        wtag_oc[buf_half]    <= oc_group;
                        wsvc                 <= W_IDLE;
                    end
                end
                default: wsvc <= W_IDLE;                    // W_REPLY
            endcase

            // ---- Parameter load ----
            if (pmem_req_fire) begin
                pl_busy   <= 1'b1;
                pl_addr_q <= o_param_mem_addr;
                pl_idx    <= pl_idx + 1'b1;
            end
            if (pmem_rsp_fire) begin
                pl_busy <= 1'b0;
            end
            if (i_param_load_done) pl_done <= 1'b1;

            // ---- Main FSM ----
            case (state)
                C_IDLE: begin
                    o_write_grant <= 1'b0;
                    wtag_valid[0] <= 1'b0;  wtag_valid[1] <= 1'b0;
                    ld_done_seen  <= 1'b0;
                    if (i_start_valid && o_start_ready) begin
                        o_ld_start <= 1'b1;                             // Image RAM -> input_buf
                        state      <= C_START;
                    end
                end

                C_START: begin // image load
                    if (i_ld_done || ld_done_seen) begin
                        ld_done_seen        <= 1'b0;
                        o_write_grant       <= 1'b1;
                        layer_idx           <= 3'd0;
                        region_sel          <= 1'b0;
                        pl_idx              <= {(`PARAM_AW+1){1'b0}};
                        pl_busy             <= 1'b0;
                        pl_done             <= 1'b0;
                        o_param_load_start  <= 1'b1;                    // seen on first clk of C_PARAM_LOAD
                        state               <= C_PARAM_LOAD;
                    end
                end

                C_PARAM_LOAD: begin // RAM owner = param
                    if (pl_done) state <= C_SET;
                end

                C_SET: begin // layer descriptor; reset tile counters
                    o_layer_cfg_valid <= 1'b1;
                    pos_group          <= {`POS_W{1'b0}};
                    oc_group           <= {`OCG_W{1'b0}};
                    og_off_q           <= {`W_AW{1'b0}};
                    tile_started <= 1'b0;
                    tcfg_sent <= 1'b0;
                    first_chunk_rdy <= 1'b0;
                    tile_in_done_seen <= 1'b0;
                    layer_done_seen <= 1'b0;
                    state <= C_W_LOAD;
                end

                C_W_LOAD: begin // tile's first weight chunk (skipped on tag hit)
                    buf_half <= first_half;
                    if (wload_skip) begin
                        first_chunk_rdy <= 1'b1;
                    end else if (!first_chunk_rdy && (wsvc == W_IDLE)) begin
                        svc_kbase     <= {`K_W{1'b0}};
                        svc_len       <= first_len;
                        wsvc <= W_ISSUE;
                    end

                    if (first_chunk_rdy && (wsvc == W_IDLE)) begin
                        state <= C_TILE_CFG;
                    end
                end

                // Send tile_cfg, then wait for i_params_ready (valid from the clk after cfg).
                C_TILE_CFG: begin
                    if (!tcfg_sent) begin
                        if (i_tile_ready) tcfg_sent <= 1'b1;
                    end else if (i_params_ready) begin
                        tile_started <= 1'b0;
                        state        <= C_PE_TILE;
                    end
                end

                // tile_start to act_path, then tile cmd to pe_cntl
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

                // PE running; mid-tile chunks are served by wsvc above.
                C_PE_WAIT: begin
                    if ((i_tile_in_done || tile_in_done_seen) && i_tile_ready)
                        state <= C_NXT_TILE;
                end

                // oc_group = inner loop, pos_group = outer loop
                C_NXT_TILE: begin
                    tile_started      <= 1'b0;
                    tcfg_sent         <= 1'b0;
                    first_chunk_rdy   <= 1'b0;
                    tile_in_done_seen <= 1'b0;

                    if (!oc_last) begin
                        oc_group  <= oc_group + 1'b1;
                        og_off_q  <= og_off_q + k_ext;
                        state <= C_W_LOAD;
                    end else if (!pos_last) begin
                        oc_group  <= {`OCG_W{1'b0}};
                        og_off_q  <= {`W_AW{1'b0}};
                        pos_group <= pos_group + 1'b1;
                        state <= C_W_LOAD;
                    end else begin
                        state <= C_LAYER_END;
                    end
                end

                // wait for out_path to finish storing the layer
                C_LAYER_END: begin
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

                default: begin  // C_DONE
                    o_write_grant <= 1'b0;
                    state         <= C_IDLE;
                end
            endcase
        end
    end

    // ---- debug ----
    // synthesis translate_off
    // VCS coverage off
    logic [8*12-1:0] state_name;
    logic [ 8*8-1:0] wsvc_name;
    logic [ 8*5-1:0] layer_name;
    logic [8*16-1:0] tile_name;
    always_comb begin
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
    // VCS coverage on
    // synthesis translate_on
endmodule

// ---- pe_cntl ----
// Per-tile MAC sequencer: feeds the 3x3 PE array and requests weight chunks.
module pe_cntl #(
    parameter integer WBUF_WORDS = 256                    // one wgt_buf half = max chunk length
) (
    input logic clk,
    input logic rst_n,

    // ---- cnn_cntl : tile command ----
    input  logic                 i_tile_valid,
    output logic                 o_tile_ready,
    input  logic [`K_W-1:0]      i_step_total,           // MAC steps per tile = K
    input  logic [`KEEP_W-1:0]   i_tile_row_mask,        // valid PE rows (positions)
    input  logic [`KEEP_W-1:0]   i_tile_col_mask,        // valid PE columns (channels)

    // ---- cnn_cntl : mid-tile chunk reload (K > 256 only) ----
    output logic                 o_chunk_req,            // level, P_PREFILL until i_chunk_loaded
    input  logic                 i_chunk_loaded,         // 1clk pulse

    // ---- wgt_ld_unit ----
    output logic                 o_wbuf_free,            // 0 only when double buffer full

    // ---- wgt_patch_gen ----
    output logic                 o_chunk_start,          // 1clk per chunk (P_PREFILL)
    output logic [`CHUNK_W-1:0]  o_chunk_word_count,
    input  logic                 i_chunk_done,           // 1clk pulse, last Word to feeder

    // ---- act_feeder / wgt_feeder ----
    output logic                 o_feed_en,              // 1 in PREFILL / FEED
    output logic                 o_tile_clear,           // feeders and skew regs
    input  logic                 i_weight_valid,
    input  logic                 i_act_valid,

    // ---- pe_core ----
    output logic                 o_step_en,
    output logic                 o_feed_valid,
    output logic                 o_acc_clear,
    output logic [`PE_N-1:0]     o_mac_valid,
    output logic [`PE_N-1:0]     o_mac_last,

    // ---- out_path ----
    input  logic                 i_result_space_ready,   // collector can accept a new tile
    input  logic                 i_tile_in_done
);
    typedef enum logic [2:0] {
        P_IDLE       = 3'd0,
        P_CLEAR      = 3'd1,
        P_PREFILL    = 3'd2,
        P_FEED       = 3'd3,
        P_CHUNK_WAIT = 3'd4,
        P_DRAIN      = 3'd5,
        P_DONE       = 3'd6
    } p_state_e;

    localparam [`K_W-1:0] K_ONE = 1;
    localparam [`CHUNK_W-1:0] C_ONE = 1;

    // min(remain, WBUF_WORDS)
    function automatic logic [`CHUNK_W-1:0] chunk_len(input logic [`K_W-1:0] remain);
        begin
            chunk_len = (remain > WBUF_WORDS) ? WBUF_WORDS[`CHUNK_W-1:0] : remain[`CHUNK_W-1:0];
        end
    endfunction

    // ---- Registers ----
    p_state_e             state;
    logic [`K_W-1:0]      k_left;             // beats left in tile; 1 = last beat
    logic [`CHUNK_W-1:0]  c_left;             // beats left in chunk; 1 = last beat
    logic [`CHUNK_W-1:0]  cur_len;            // held constant during the chunk
    logic [`KEEP_W-1:0]   row_mask_q;
    logic [`KEEP_W-1:0]   col_mask_q;
    logic                 reader_done_seen;
    logic                 next_req;
    logic                 next_ready;         // next chunk is in the other half
    logic                 tile_in_done_seen;
    logic                 space_seen;         // result space seen in P_IDLE
    logic [4:0]           valid_pipe;         // MAC token per diagonal d = r + c
    logic [4:0]           last_pipe;          // last-MAC token per diagonal

    logic inject;
    assign inject             = (state == P_FEED)  && i_act_valid && i_weight_valid;
    logic drain_advance;
    assign drain_advance      = (state == P_DRAIN);
    logic tile_last_beat;
    assign tile_last_beat     = (k_left == K_ONE);
    logic chunk_last_beat;
    assign chunk_last_beat    = (c_left == C_ONE);
    logic feeding;
    assign feeding            = (state == P_PREFILL) || (state == P_FEED);
    logic clearing;
    assign clearing           = (state == P_CLEAR);

    // Treat K = 0 as 1 so k_left cannot hang.
    logic [`K_W-1:0] k_init;
    assign k_init = (i_step_total == {`K_W{1'b0}}) ? K_ONE : i_step_total;

    // space_seen needed: result space drops on tile_cfg, which precedes the tile cmd.
    assign o_tile_ready = (state == P_IDLE) && (i_result_space_ready || space_seen);

    assign o_chunk_req = next_req;

    // Block loads only when a chunk is being read and the other half is already full.
    logic rd_active;
    assign rd_active = feeding && !reader_done_seen;
    assign o_wbuf_free        = (state == P_IDLE) || !(rd_active && next_ready);

    assign o_chunk_start        = (state == P_PREFILL);  // P_PREFILL lasts 1clk
    assign o_chunk_word_count   = cur_len;
    assign o_feed_en            = feeding;

    assign o_tile_clear         = clearing;
    assign o_acc_clear          = clearing;

    assign o_step_en            = inject || drain_advance;
    assign o_feed_valid         = inject;

    // PE n = 3*r + c uses pipe[r + c], gated by its row/col mask.
    genvar gr, gc;
    generate
        for (gr = 0; gr < `KEEP_W; gr = gr + 1) begin : g_row
            for (gc = 0; gc < `KEEP_W; gc = gc + 1) begin : g_col
                assign o_mac_valid[`KEEP_W*gr + gc] = valid_pipe[gr + gc] && row_mask_q[gr] && col_mask_q[gc];
                assign o_mac_last [`KEEP_W*gr + gc] = last_pipe [gr + gc] && row_mask_q[gr] && col_mask_q[gc];
            end
        end
    endgenerate

    // ---- FSM ----
    always_ff @(posedge clk or negedge rst_n) begin
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

            // Latch 1clk pulses; i_tile_in_done can arrive while still in P_DRAIN.
            if (i_chunk_done)   reader_done_seen <= 1'b1;
            if (i_tile_in_done) tile_in_done_seen <= 1'b1;
            if (i_chunk_loaded) begin
                next_req   <= 1'b0;
                next_ready <= 1'b1;
            end

            case (state)
                P_IDLE: begin
                    tile_in_done_seen <= 1'b0;
                    if (i_result_space_ready) space_seen <= 1'b1;
                    if (i_tile_valid && o_tile_ready) begin
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
                    reader_done_seen <= i_chunk_done;
                    next_ready       <= 1'b0;
                    next_req         <= (k_left > WBUF_WORDS);   // prefetch next chunk into other half
                    state <= P_FEED;
                end

                P_FEED: begin
                    if (inject) begin
                        valid_pipe <= {valid_pipe[3:0], 1'b1};
                        last_pipe  <= {last_pipe[3:0], tile_last_beat};
                        k_left     <= k_left - 1'b1;
                        c_left     <= c_left - 1'b1;

                        if (tile_last_beat) state <= P_DRAIN;
                        else if (chunk_last_beat)
                            state <= P_CHUNK_WAIT;
                    end
                end

                // Hold the array (step = 0) until the next chunk is ready; usually 1clk.
                P_CHUNK_WAIT: begin
                    if (next_ready || i_chunk_loaded) begin
                        c_left  <= chunk_len(k_left);
                        cur_len <= chunk_len(k_left);
                        state   <= P_PREFILL;
                    end
                end

                // flush the diagonal pipe
                P_DRAIN: begin
                    if (drain_advance) begin
                        valid_pipe <= {valid_pipe[3:0], 1'b0};
                        last_pipe  <= {last_pipe[3:0], 1'b0};
                        if (valid_pipe[3:0] == 4'b0000) state <= P_DONE;
                    end
                end

                // wait for out_path tile_in_done
                P_DONE: begin
                    if (i_tile_in_done || tile_in_done_seen) state <= P_IDLE;
                end

                default: state <= P_IDLE;
            endcase
        end
    end

    // ---- debug ----
    // synthesis translate_off
    // VCS coverage off
    logic [8*12-1:0] state_name;
    always_comb begin
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
    // VCS coverage on
    // synthesis translate_on
endmodule

// =============================================================================
// top_cnn_cntl : cnn_cntl (layer/tile sequencing) + pe_cntl (per-tile MAC control)
// Tile cmd: valid/ready; chunk reload: pe_cntl level request, cnn_cntl 1clk reply.
// =============================================================================
module top_cnn_cntl #(
    parameter integer NUM_LAYERS = 4,
    parameter integer WBUF_WORDS = 256,                    // one wgt_buf half = max chunk length

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

    // per layer Requant M / S
    parameter [31:0] L0_QM = 32'd1463994,
    parameter [ 5:0] L0_QS = 6'd30,
    parameter [31:0] L1_QM = 32'd4487009,
    parameter [ 5:0] L1_QS = 6'd30,
    parameter [31:0] L2_QM = 32'd849386,
    parameter [ 5:0] L2_QS = 6'd30,
    parameter [31:0] L3_QM = 32'd1046256,
    parameter [ 5:0] L3_QS = 6'd30
) (
    input logic clk,
    input logic rst_n,

    // Ports belong to cnn_cntl unless tagged [P] (pe_cntl).
    // ---- AXI4-Lite CSR ----
    input  logic                 i_start_valid,
    output logic                 o_start_ready,
    output logic                 o_busy,

    // ---- act_ld_unit ----
    output logic                 o_img_ld_start,
    input  logic                 i_ld_done,              // 1clk pulse
    output logic                 o_writer_mode,          // 0=image load, 1=result write

    // ---- act_patch_gen / fc_gen : layer descriptor ----
    output logic                 o_layer_cfg_valid,
    output logic [`ACT_AW-1:0]   o_src_base,
    output logic [`DIM_W-1:0]    o_in_w,
    output logic [`DIM_W-1:0]    o_in_h,
    output logic [`CH_W-1:0]     o_in_c,
    output logic [1:0]           o_stride,
    output logic                 o_pad_en,
    output logic [`K_W-1:0]      o_k_total,
    output logic                 o_path_sel,             // 0=Conv, 1=FC

    // ---- Tile setting ----
    output logic                 o_pg_tile_start,
    output logic                 o_fc_tile_start,
    output logic [13:0]          o_pos_base,             // zero-extended from 12b
    output logic [`KEEP_W-1:0]   o_row_mask,
    output logic [`KEEP_W-1:0]   o_col_mask,
    output logic                 o_tile_cfg_valid,
    output logic [`OCB_W-1:0]    o_out_ch_base,
    output logic                 o_tile_last,
    output logic                 o_relu_en,
    output logic [5:0]           o_param_base,           // lower 6b of 7b value
    input  logic                 i_params_ready,

    // ---- Layer output path ----
    output logic                 o_output_cfg_valid,
    output logic [`ACT_AW-1:0]   o_dst_base,
    output logic [`CH_W-1:0]     o_out_c,
    output logic [`DIM_W-1:0]    o_pool_in_w,
    output logic [`DIM_W-1:0]    o_pool_in_h,
    output logic [`CH_W-1:0]     o_pool_c,
    output logic                 o_pool_en,
    output logic                 o_is_final_layer,

    // ---- wgt_ld_unit ----
    output logic                 o_wload_start,          // 1clk pulse
    input  logic                 i_wload_ready,
    output logic [15:0]          o_mem_base,             // logical Word address
    output logic [`CHUNK_W-1:0]  o_load_chunk_len,
    output logic                 o_buf_half,             // target wgt_buf half
    input  logic                 i_wload_done,           // 1clk pulse
    output logic                 o_wbuf_free,            // [P]

    // ---- wgt_patch_gen ----
    output logic                 o_reader_start,         // [P]
    output logic [`CHUNK_W-1:0]  o_reader_chunk_len,     // [P]
    input  logic                 i_reader_done,          // [P]

    // ---- Feeder ----
    output logic [`KEEP_W-1:0]   o_pe_col_mask,          // = o_col_mask
    output logic                 o_feeder_en,            // [P]
    output logic                 o_tile_clear,           // [P]
    input  logic                 i_weight_valid,         // [P]
    input  logic                 i_act_valid,            // [P]

    // ---- pe_core ----
    output logic                 o_step_en,              // [P]
    output logic                 o_feed_valid,           // [P]
    output logic                 o_acc_clear,            // [P]
    output logic [`PE_N-1:0]     o_mac_valid,            // [P]
    output logic [`PE_N-1:0]     o_mac_last,             // [P]

    // ---- output_fifo ----
    input  logic                 i_result_space_ready,   // [P]

    // ---- Param RAM ----
    output logic                 o_ram_owner,            // 0=weight, 1=param
    output logic [`PARAM_AW-1:0] o_param_mem_addr,
    input  logic [31:0]          i_param_mem_data,       // signed INT32 Bias

    // ---- param_buf ----
    output logic                 o_param_wr_en,
    output logic [5:0]           o_param_wr_addr,        // lower 6b of 7b value
    output logic [31:0]          o_param_wr_data,
    output logic                 o_param_load_start,     // 1clk pulse
    input  logic                 i_param_load_done,      // 1clk pulse
    output logic [31:0]          o_quant_multiplier,
    output logic [5:0]           o_quant_shift,          // 0..30

    // ---- Done ----
    input  logic                 i_tile_in_done,         // both cnn_cntl and pe_cntl
    input  logic                 i_layer_done,
    input  logic                 i_done_status,

    // ---- Debug ----
    output logic [2:0]           o_layer_idx,
    output logic [3:0]           o_cnn_state,
    output logic                 o_pe_cmd_ready_dbg      // [P] TB observation only
);

    logic pe_cmd_valid, pe_cmd_ready;
    logic [`K_W-1:0] pe_step_total;
    logic [`KEEP_W-1:0] pe_row_mask, pe_col_mask;

    // Inner ports use spec names; outer ports keep the datapath names.
    // Width bridge: zero-extend / truncate to receiver widths.
    logic [`POS_W-1:0]    pos_base_12;
    logic [`W_AW-1:0]     mem_base_16;
    logic [`PARAM_AW-1:0] param_base_7, param_wr_addr_7;
    assign o_pos_base      = {2'b00, pos_base_12};
    assign o_mem_base      = mem_base_16;
    assign o_param_base    = param_base_7[5:0];
    assign o_param_wr_addr = param_wr_addr_7[5:0];

    assign o_pe_col_mask        = o_col_mask;
    assign o_output_cfg_valid   = o_layer_cfg_valid;
    assign o_pool_c             = o_out_c;

    logic chunk_req, chunk_loaded;
    assign o_pe_cmd_ready_dbg   = pe_cmd_ready;

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
        .o_ram_base(),                      // no consumer yet
        .o_ld_word_count(),                 // no consumer yet
        .o_fc_in_count(),                   // fc_gen uses o_k_total
        .o_is_fc(),                         // = o_path_sel
        .o_patch_base(),                    // = o_pos_base
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

    // ---- debug ----
    // synthesis translate_off
    // VCS coverage off
    function automatic logic [8*12-1:0] ljust12(input logic [8*12-1:0] s);
        int i;
        begin
            ljust12 = s;
            for (i = 0; i < 12; i = i + 1)
            if (ljust12[8*12-1-:8] == 8'h00) ljust12 = {ljust12[8*11-1:0], " "};
        end
    endfunction

    logic [8*12-1:0] cnn_state_name;
    assign cnn_state_name = U_CNN_CNTL.state_name;
    logic [ 8*8-1:0] wsvc_name;
    assign wsvc_name = U_CNN_CNTL.wsvc_name;
    logic [8*16-1:0] tile_name;
    assign tile_name = U_CNN_CNTL.tile_name;
    logic [8*12-1:0] pe_state_name;
    assign pe_state_name = U_PE_CNTL.state_name;

    logic [8*27-1:0] ctrl_state_name;
    always_comb
        ctrl_state_name = {
            ljust12(cnn_state_name), " / ", ljust12(pe_state_name)
        };
    // VCS coverage on
    // synthesis translate_on
endmodule
