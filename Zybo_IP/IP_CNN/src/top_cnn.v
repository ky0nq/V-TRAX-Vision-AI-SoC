`timescale 1ns / 1ps
`include "cnn_defs.vh"

module top_cnn #(
    parameter [31:0] IMG_RAM_BASE = 32'd0,
    parameter [12:0] IMG_WORDS    = 13'd4096,
    // Default Requant M / S values = Model C export 
    //   q = sat_int8( round( (acc + bias) * M / 2^S ) ). 
    //   L3 = ANGLE_MULT / ANGLE_SHIFT of the final FC2 layer (1 LSB = 1 degree)
    parameter [31:0] L0_QM = 32'd3157292,
    parameter [ 5:0] L0_QS = 6'd30,
    parameter [31:0] L1_QM = 32'd11411101,
    parameter [ 5:0] L1_QS = 6'd30,
    parameter [31:0] L2_QM = 32'd3791004,
    parameter [ 5:0] L2_QS = 6'd30,
    // L3_QM/QS = Final ANGLE_MULT/ANGLE_SHIFT
    parameter [31:0] L3_QM = 32'd7489321,
    parameter [ 5:0] L3_QS = 6'd30
) (
    input wire clk,
    input wire rst_n,

    // ---- AXI4-Lite CSR --------------------------------------------------
    input  wire       i_start_valid,
    output wire       o_start_ready,
    output wire       o_busy,
    input  wire       i_irq_en,
    input  wire       i_irq_clear,
    output wire [7:0] o_final_result,
    output wire       o_done_status,
    output wire       o_irq,

    // ---- Image RAM -------------------------------------------------------
    output wire [11:0] o_img_rd_addr,
    input  wire [23:0] i_img_rdata,

    // ---- Parameter RAM (Weight + Bias)------------------------------------
    //   word 0 .. 45249     : weight - i_rdata[23:0]
    //   word 45250 .. 45292 : bias   - i_rdata[31:0]
    output wire [15:0] o_ram_rd_addr,
    input  wire [31:0] i_rdata,

    // ---- Debugging -------------------------------------------------------
    output wire [2:0] o_layer_idx,
    output wire [3:0] o_cnn_state
);

    // ---- top_cnn_cntl -> act_path ----------------------------------------
    wire c_img_ld_start;
    wire c_pg_tile_start, c_fc_tile_start;
    wire [13:0] c_src_base;
    wire [13:0] c_pos_base;
    wire [ 5:0] c_in_c;
    wire [6:0] c_in_h, c_in_w;
    wire [ 1:0] c_stride;
    wire        c_pad_en;
    wire [12:0] c_k_total;
    wire [ 2:0] c_row_mask;
    wire        c_path_sel;
    wire c_feeder_en, c_tile_clear;

    // ---- top_cnn_cntl -> wgt_path ----------------------------------------
    wire        c_wload_start;
    wire [15:0] c_mem_base;
    wire [ 8:0] c_load_chunk_len;
    wire        c_buf_half;
    wire        c_wbuf_free;
    wire        c_reader_start;
    wire [ 8:0] c_reader_chunk_len;
    wire [ 2:0] c_pe_col_mask;

    // ---- top_cnn_cntl -> pe_core -----------------------------------------
    wire c_step_en, c_feed_valid, c_acc_clear;
    wire [8:0] c_mac_valid, c_mac_last;

    // ---- top_cnn_cntl -> out_path ----------------------------------------
    wire c_layer_cfg_valid, c_tile_cfg_valid;
    wire c_is_final, c_pool_en, c_relu_en, c_tile_last;
    wire [6:0] c_pool_in_w, c_pool_in_h;
    wire [ 5:0] c_out_c;
    wire [13:0] c_dst_base;
    wire [31:0] c_quant_m;
    wire [ 5:0] c_quant_s;
    wire [ 5:0] c_param_base;
    wire [ 4:0] c_out_ch_base;
    wire [ 2:0] c_col_mask;
    wire c_param_load_start, c_param_wr_en;
    wire [ 5:0] c_param_wr_addr;
    wire [31:0] c_param_wr_data;
    wire        c_writer_mode;

    // ---- act_path output -----------------------------------------------------
    wire        a_ld_done;
    wire [23:0] a_data;
    wire [ 2:0] a_keep;
    wire        a_valid;

    // ---- wgt_path output -----------------------------------------------------
    wire w_ld_done, w_ld_ready;
    wire        w_chunk_done;
    wire [23:0] w_data;
    wire [ 2:0] w_keep;
    wire        w_valid;

    // ---- pe_core output ------------------------------------------------------
    wire p_act_ready, p_wgt_ready;
    wire [287:0] p_result_data;
    wire [  8:0] p_result_valid;

    // ---- out_path output -----------------------------------------------------
    wire         r_result_space_ready;
    wire r_param_load_done, r_params_ready;
    wire        r_wr_en;
    wire [13:0] r_wr_addr;
    wire [23:0] r_wr_data;
    wire [ 2:0] r_wr_be;
    wire r_tile_in_done, r_layer_done, r_done_status;
    wire [31:0] r_final_result;

    wire [15:0] wgt_rd_addr;
    wire [ 6:0] param_mem_addr;

    assign o_done_status  = r_done_status;
    assign o_final_result = r_final_result[7:0];

    // Parameter RAM Address: Select the bias region during bias loading (cnn_cntl C_PARAM_LOAD, ram_owner = 1); 
    // otherwise, select the weight address.
    localparam [15:0] PRM_RAM_BASE = 16'd45250; // = First word after the FC2 weight region (16'hB0C2)
    wire ram_owner;  // cnn_cntl.o_ram_owner. Used only within top_cnn.
    assign o_ram_rd_addr = ram_owner ? (PRM_RAM_BASE + {9'd0, param_mem_addr}) : wgt_rd_addr;

    top_cnn_cntl #(
        .L0_QM(L0_QM),
        .L0_QS(L0_QS),
        .L1_QM(L1_QM),
        .L1_QS(L1_QS),
        .L2_QM(L2_QM),
        .L2_QS(L2_QS),
        .L3_QM(L3_QM),
        .L3_QS(L3_QS)
    ) U_TOP_CNN_CNTL (
        .clk  (clk),
        .rst_n(rst_n),

        // ---- AXI4-Lite CSR ------------------------------------------------
        .i_start_valid(i_start_valid),
        .o_start_ready(o_start_ready),
        .o_busy       (o_busy),

        // ---- act_path -----------------------------------------------------
        .o_img_ld_start (c_img_ld_start),
        .i_ld_done      (a_ld_done),
        .o_src_base     (c_src_base),
        .o_in_w         (c_in_w),
        .o_in_h         (c_in_h),
        .o_in_c         (c_in_c),
        .o_stride       (c_stride),
        .o_pad_en       (c_pad_en),
        .o_k_total      (c_k_total),
        .o_path_sel     (c_path_sel),
        .o_pg_tile_start(c_pg_tile_start),
        .o_fc_tile_start(c_fc_tile_start),
        .o_pos_base     (c_pos_base),
        .o_row_mask     (c_row_mask),
        .o_feeder_en    (c_feeder_en),
        .o_tile_clear   (c_tile_clear),
        .i_act_valid    (a_valid),

        // ---- wgt_path -----------------------------------------------------
        .o_wload_start     (c_wload_start),
        .i_wload_ready     (w_ld_ready),
        .o_mem_base        (c_mem_base),
        .o_load_chunk_len  (c_load_chunk_len),
        .o_buf_half        (c_buf_half),
        .i_wload_done      (w_ld_done),
        .o_wbuf_free       (c_wbuf_free),
        .o_reader_start    (c_reader_start),
        .o_reader_chunk_len(c_reader_chunk_len),
        .i_reader_done     (w_chunk_done),
        .o_pe_col_mask     (c_pe_col_mask),
        .i_weight_valid    (w_valid),

        // ---- pe_core ------------------------------------------------------
        .o_step_en   (c_step_en),
        .o_feed_valid(c_feed_valid),
        .o_acc_clear (c_acc_clear),
        .o_mac_valid (c_mac_valid),
        .o_mac_last  (c_mac_last),

        // ---- out_path -----------------------------------------------------
        .o_writer_mode       (c_writer_mode),
        .o_layer_cfg_valid   (c_layer_cfg_valid),
        .o_col_mask          (c_col_mask),
        .o_tile_cfg_valid    (c_tile_cfg_valid),
        .o_out_ch_base       (c_out_ch_base),
        .o_tile_last         (c_tile_last),
        .o_relu_en           (c_relu_en),
        .o_param_base        (c_param_base),
        .i_params_ready      (r_params_ready),
        .o_output_cfg_valid  (),
        .o_dst_base          (c_dst_base),
        .o_out_c             (c_out_c),
        .o_pool_in_w         (c_pool_in_w),
        .o_pool_in_h         (c_pool_in_h),
        .o_pool_c            (),
        .o_pool_en           (c_pool_en),
        .o_is_final_layer    (c_is_final),
        .i_result_space_ready(r_result_space_ready),
        .o_param_wr_en       (c_param_wr_en),
        .o_param_wr_addr     (c_param_wr_addr),
        .o_param_wr_data     (c_param_wr_data),
        .o_param_load_start  (c_param_load_start),
        .i_param_load_done   (r_param_load_done),
        .o_quant_multiplier  (c_quant_m),
        .o_quant_shift       (c_quant_s),
        .i_tile_in_done      (r_tile_in_done),
        .i_layer_done        (r_layer_done),
        .i_done_status       (r_done_status),

        // ---- Param RAM ----------------------------------------------------
        .o_ram_owner     (ram_owner),
        .o_param_mem_addr(param_mem_addr),
        .i_param_mem_data(i_rdata),

        // ---- Debugging ----------------------------------------------------
        .o_layer_idx       (o_layer_idx),
        .o_cnn_state       (o_cnn_state),
        .o_pe_cmd_ready_dbg()
    );

    act_path U_ACT_PATH (
        .clk  (clk),
        .rst_n(rst_n),

        // ---- cnn_cntl -----------------------------------------------------
        .i_ld_start     (c_img_ld_start),
        .i_ram_base     (IMG_RAM_BASE),
        .i_ld_word_count(IMG_WORDS),
        .o_ld_done      (a_ld_done),
        .i_fc_mode      (c_path_sel),
        .i_pg_tile_start(c_pg_tile_start),
        .i_fc_tile_start(c_fc_tile_start),
        .i_src_base     (c_src_base),
        .i_pos_base     (c_pos_base),
        .i_in_c         (c_in_c),
        .i_in_h         (c_in_h),
        .i_in_w         (c_in_w),
        .i_stride       (c_stride),
        .i_pad_en       (c_pad_en),
        .i_k_total      (c_k_total),
        .i_row_mask     (c_row_mask),
        .i_fc_in_count  (c_k_total),

        // ---- pe_cntl ------------------------------------------------------
        .i_feed_en(c_feeder_en),
        .i_clear  (c_tile_clear),
        .o_valid  (a_valid),

        // ---- Image RAM ----------------------------------------------------
        //.o_ram_rd_en            (o_img_rd_en),
        .o_ram_rd_addr(o_img_rd_addr),
        .i_ram_rdata  (i_img_rdata),

        // ---- out_path -----------------------------------------------------
        .i_wr_en  (r_wr_en),
        .i_wr_addr(r_wr_addr),
        .i_wr_data(r_wr_data),
        .i_wr_be  (r_wr_be),

        // ---- pe_core ------------------------------------------------------
        .o_data (a_data),
        .o_keep (a_keep),
        .i_ready(p_act_ready)
    );

    wgt_path U_WGT_PATH (
        .clk  (clk),
        .rst_n(rst_n),

        // ---- cnn_cntl -----------------------------------------------------
        .i_ld_start      (c_wload_start),
        .i_mem_base      (c_mem_base),
        .i_load_chunk_len(c_load_chunk_len),
        .i_buf_half      (c_buf_half),
        .o_ld_done       (w_ld_done),
        .o_ld_ready      (w_ld_ready),
        .i_col_mask      (c_pe_col_mask),

        // ---- pe_cntl ------------------------------------------------------
        .i_buf_free        (c_wbuf_free),
        .i_chunk_start     (c_reader_start),
        .i_chunk_word_count(c_reader_chunk_len),
        .o_chunk_done      (w_chunk_done),
        .i_feed_en         (c_feeder_en),
        .i_clear           (c_tile_clear),
        .o_valid           (w_valid),

        // ---- Weight RAM ---------------------------------------------------
        //.o_mem_rd_en            (o_wgt_rd_en),
        .o_mem_rd_addr(wgt_rd_addr),
        .i_mem_rdata  (i_rdata[23:0]),

        // ---- pe_core ------------------------------------------------------
        .o_data (w_data),
        .o_keep (w_keep),
        .i_ready(p_wgt_ready)
    );

    pe_core U_PE_CORE (
        .clk  (clk),
        .rst_n(rst_n),

        // ---- act_path -----------------------------------------------------
        .i_act_data (a_data),
        .i_act_valid(a_valid),
        .o_act_ready(p_act_ready),

        // ---- wgt_path -----------------------------------------------------
        .i_wgt_data (w_data),
        .i_wgt_valid(w_valid),
        .o_wgt_ready(p_wgt_ready),

        // ---- pe_cntl ------------------------------------------------------
        .i_step_en    (c_step_en),
        .i_feed_valid (c_feed_valid),
        .i_askew_clear(c_tile_clear),
        .i_wskew_clear(c_tile_clear),
        .i_acc_clear  (c_acc_clear),
        .i_mac_valid  (c_mac_valid),
        .i_mac_last   (c_mac_last),

        // ---- out_path -----------------------------------------------------
        .o_result_data (p_result_data),
        .o_result_valid(p_result_valid)
    );

    out_path U_OUT_PATH (
        .clk  (clk),
        .rst_n(rst_n),

        // ---- cnn_cntl -----------------------------------------------------
        .i_layer_cfg_valid (c_layer_cfg_valid),
        .i_is_fc           (c_path_sel),
        .i_is_final_layer  (c_is_final),
        .i_pool_en         (c_pool_en),
        .i_conv_w          (c_pool_in_w),
        .i_conv_h          (c_pool_in_h),
        .i_out_channels    (c_out_c),
        .i_dst_base        (c_dst_base),
        .i_relu_en         (c_relu_en),
        .i_quant_multiplier(c_quant_m),
        .i_quant_shift     (c_quant_s),
        .i_bias_base       (c_param_base),
        .i_angle_multiplier(c_quant_m),
        .i_angle_shift     (c_quant_s),
        .i_tile_cfg_valid  (c_tile_cfg_valid),
        .i_patch_base      (c_pos_base[11:0]),
        .i_out_ch_base     (c_out_ch_base),
        .i_row_mask        (c_row_mask),
        .i_col_mask        (c_col_mask),
        .i_tile_last       (c_tile_last),
        .i_param_load_start(c_param_load_start),
        .i_param_wr_en     (c_param_wr_en),
        .i_param_wr_addr   (c_param_wr_addr),
        .i_param_wr_data   (c_param_wr_data),
        .o_param_load_done (r_param_load_done),
        .o_params_ready    (r_params_ready),
        .i_write_grant     (c_writer_mode),
        .o_tile_in_done    (r_tile_in_done),
        .o_layer_done      (r_layer_done),
        .o_done_status     (r_done_status),

        // ---- pe_cntl ------------------------------------------------------
        .o_result_space_ready(r_result_space_ready),

        // ---- pe_core ------------------------------------------------------
        .i_result_data (p_result_data),
        .i_result_valid(p_result_valid),

        // ---- act_path -----------------------------------------------------
        .o_wr_en  (r_wr_en),
        .o_wr_addr(r_wr_addr),
        .o_wr_data(r_wr_data),
        .o_wr_be  (r_wr_be),

        // ---- AXI4-Lite CSR ------------------------------------------------
        .i_irq_en      (i_irq_en),
        .i_irq_clear   (i_irq_clear),
        .o_final_result(r_final_result),
        .o_irq         (o_irq)
    );

endmodule