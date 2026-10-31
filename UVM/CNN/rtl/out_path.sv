`timescale 1ns / 1ps

module out_path (
    input logic clk,
    input logic rst_n,

    input logic               i_layer_cfg_valid,
    input logic               i_is_fc,
    input logic               i_is_final_layer,
    input logic               i_pool_en,
    input logic        [ 6:0] i_conv_w,
    input logic        [ 6:0] i_conv_h,
    input logic        [ 5:0] i_out_channels,
    input logic        [13:0] i_dst_base,
    input logic               i_relu_en,
    input logic signed [31:0] i_quant_multiplier,
    input logic        [ 5:0] i_quant_shift,
    input logic        [ 5:0] i_bias_base,

    // Final FC2 angle requantization
    input logic signed [31:0] i_angle_multiplier,
    input logic        [ 5:0] i_angle_shift,

    input logic        i_tile_cfg_valid,
    input logic [11:0] i_patch_base,
    input logic [ 4:0] i_out_ch_base,
    input logic [ 2:0] i_row_mask,
    input logic [ 2:0] i_col_mask,
    input logic        i_tile_last,

    input logic [287:0] i_result_data,
    input logic [  8:0] i_result_valid,

    output logic o_result_space_ready,

    input logic i_param_load_start,

    input logic               i_param_wr_en,
    input logic        [ 5:0] i_param_wr_addr,
    input logic signed [31:0] i_param_wr_data,

    output logic o_param_load_done,

    output logic o_params_ready,

    input logic i_write_grant,

    output logic        o_wr_en,
    output logic [13:0] o_wr_addr,
    output logic [23:0] o_wr_data,
    output logic [ 2:0] o_wr_be,

    input logic i_irq_en,
    input logic i_irq_clear,

    output logic o_tile_in_done,
    output logic o_layer_done,

    output logic signed [31:0] o_final_result,
    output logic               o_done_status,
    output logic               o_irq
);
    // ---- layer config registers ----
    logic               is_fc_reg;
    logic               is_final_layer_reg;
    logic               pool_en_reg;
    logic        [ 6:0] conv_w_reg;
    logic        [ 5:0] out_channels_reg;
    logic        [13:0] dst_base_reg;
    logic               relu_en_reg;
    logic signed [31:0] quant_multiplier_reg;
    logic        [ 5:0] quant_shift_reg;
    logic        [ 5:0] bias_base_reg;

    logic signed [31:0] angle_multiplier_reg;
    logic        [ 5:0] angle_shift_reg;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_fc_reg            <= 1'b0;
            is_final_layer_reg   <= 1'b0;
            pool_en_reg          <= 1'b0;
            conv_w_reg           <= 7'd0;
            out_channels_reg     <= 6'd0;
            dst_base_reg         <= 14'd0;
            relu_en_reg          <= 1'b0;
            quant_multiplier_reg <= 32'd0;
            quant_shift_reg      <= 6'd0;
            bias_base_reg        <= 6'd0;
            angle_multiplier_reg <= 32'd0;
            angle_shift_reg      <= 6'd0;
        end else if (i_layer_cfg_valid) begin
            is_fc_reg            <= i_is_fc;
            is_final_layer_reg   <= i_is_final_layer;
            pool_en_reg          <= i_pool_en;
            conv_w_reg           <= i_conv_w;
            out_channels_reg     <= i_out_channels;
            dst_base_reg         <= i_dst_base;
            relu_en_reg          <= i_relu_en;
            quant_multiplier_reg <= i_quant_multiplier;
            quant_shift_reg      <= i_quant_shift;
            bias_base_reg        <= i_bias_base;
            angle_multiplier_reg <= i_angle_multiplier;
            angle_shift_reg      <= i_angle_shift;
        end
    end

    // Tile config passes straight through: cnn_cntl only sends it when both consumers can accept.
    // The two readys below are for verification only (both should be 1).
    logic        fifo_cfg_ready;
    logic        pp_cfg_ready;
    logic        tile_cfg_fire;
    assign tile_cfg_fire = i_tile_cfg_valid;

    // ---- output_fifo wires ----
    logic        [95:0] fifo_data;
    logic               fifo_valid;
    logic        [ 2:0] fifo_keep;
    logic        [18:0] fifo_meta;
    logic               fifo_ready;

    // ---- post_process wires ----
    logic               pp_params_ready;

    logic               pp_bias_req_valid;
    logic               pp_bias_req_ready;
    logic        [ 5:0] pp_bias_addr;

    logic signed [31:0] pp_bias_data;
    logic               pp_bias_rsp_valid;
    logic               pp_bias_rsp_ready;

    logic        [23:0] pp_data;
    logic               pp_valid;
    logic        [ 2:0] pp_keep;
    logic        [18:0] pp_meta;
    logic               pp_ready;

    logic signed [ 7:0] pp_final_data;
    logic               pp_final_valid;
    logic               pp_final_ready;

    logic               params_loaded;

    assign o_params_ready = pp_params_ready;

    // ---- pooling_unit wires ----
    logic        [23:0] pool_data;
    logic               pool_valid;
    logic        [ 2:0] pool_keep;
    logic        [18:0] pool_meta;
    logic               pool_ready;

    logic               pool_tile_in_done;
    logic               result_final_tile_done;

    param_buf #(
        .PARAM_TOTAL(43)
    ) u_param_buf (
        .clk  (clk),
        .rst_n(rst_n),

        // cnn_cntl -> param_buf
        .i_load_start(i_param_load_start),
        .i_wr_en     (i_param_wr_en),
        .i_wr_addr   (i_param_wr_addr),
        .i_wr_data   (i_param_wr_data),

        // Load Status
        .o_load_done(o_param_load_done),
        .o_loaded   (params_loaded),

        // post_process -> param_buf : Bias Read Request
        .i_rd_req_valid(pp_bias_req_valid),
        .o_rd_req_ready(pp_bias_req_ready),
        .i_rd_addr     (pp_bias_addr),

        // param_buf -> post_process : Bias Read Response
        .o_rd_data     (pp_bias_data),
        .o_rd_rsp_valid(pp_bias_rsp_valid),
        .i_rd_rsp_ready(pp_bias_rsp_ready)
    );

    output_fifo u_output_fifo (
        .clk  (clk),
        .rst_n(rst_n),

        .i_cfg_valid  (tile_cfg_fire),
        .i_patch_base (i_patch_base),
        .i_out_ch_base(i_out_ch_base),
        .i_row_mask   (i_row_mask),
        .i_col_mask   (i_col_mask),
        .i_tile_last  (i_tile_last),

        .i_is_fc (is_fc_reg),
        .i_conv_w(conv_w_reg),

        .i_result_data (i_result_data),
        .i_result_valid(i_result_valid),

        .o_cfg_ready         (fifo_cfg_ready),
        .o_result_space_ready(o_result_space_ready),

        .o_data (fifo_data),
        .o_valid(fifo_valid),
        .i_ready(fifo_ready),
        .o_keep (fifo_keep),
        .o_meta (fifo_meta)
    );

    post_process u_post_process (
        .clk  (clk),
        .rst_n(rst_n),

        // Tile / Layer Configuration
        .i_cfg_valid(tile_cfg_fire),
        .o_cfg_ready(pp_cfg_ready),

        .i_col_mask   (i_col_mask),
        .i_out_ch_base(i_out_ch_base),

        .i_bias_base     (bias_base_reg),
        .i_relu_en       (relu_en_reg),
        .i_is_final_layer(is_final_layer_reg),

        .i_quant_multiplier(quant_multiplier_reg),
        .i_quant_shift     (quant_shift_reg),

        .i_angle_multiplier(angle_multiplier_reg),
        .i_angle_shift     (angle_shift_reg),

        // Parameter Buffer Interface
        .i_params_loaded(params_loaded),
        .o_params_ready (pp_params_ready),

        // Bias Read Request
        .o_bias_req_valid(pp_bias_req_valid),
        .i_bias_req_ready(pp_bias_req_ready),
        .o_bias_addr     (pp_bias_addr),

        // Bias Read Response
        .i_bias_data     (pp_bias_data),
        .i_bias_rsp_valid(pp_bias_rsp_valid),
        .o_bias_rsp_ready(pp_bias_rsp_ready),

        // output_fifo -> post_process
        .i_data (fifo_data),
        .i_valid(fifo_valid),
        .o_ready(fifo_ready),
        .i_keep (fifo_keep),
        .i_meta (fifo_meta),

        // Normal Output
        .o_data (pp_data),
        .o_valid(pp_valid),
        .i_ready(pp_ready),
        .o_keep (pp_keep),
        .o_meta (pp_meta),

        // Final Output
        .o_final_data (pp_final_data),
        .o_final_valid(pp_final_valid),
        .i_final_ready(pp_final_ready)
    );

    pooling_unit u_pooling_unit (
        .clk  (clk),
        .rst_n(rst_n),

        // Layer Configuration
        .i_cfg_valid(i_layer_cfg_valid),
        .i_pool_en  (i_pool_en),
        .i_in_w     (i_conv_w),
        .i_in_h     (i_conv_h),
        .i_channels (i_out_channels),

        // post_process -> pooling_unit
        .i_data (pp_data),
        .i_valid(pp_valid),
        .o_ready(pp_ready),
        .i_keep (pp_keep),
        .i_meta (pp_meta),

        // pooling_unit -> result_buf
        .o_data (pool_data),
        .o_valid(pool_valid),
        .i_ready(pool_ready),
        .o_keep (pool_keep),
        .o_meta (pool_meta),

        // Tile Input Completion
        .o_tile_in_done(pool_tile_in_done)
    );

    result_buf u_result_buf (
        .clk  (clk),
        .rst_n(rst_n),

        // Layer Configuration
        .i_cfg_valid      (i_layer_cfg_valid),
        .i_is_final_layer (i_is_final_layer),
        .i_dst_base       (i_dst_base),
        .i_dst_channels   (i_out_channels),

        // pooling_unit -> result_buf
        .i_data       (pool_data),
        .i_valid      (pool_valid),
        .o_ready      (pool_ready),
        .i_keep       (pool_keep),
        .i_meta       (pool_meta),

        // Input Buffer Write Port
        .i_write_grant(i_write_grant),
        .o_wr_en      (o_wr_en),
        .o_wr_addr    (o_wr_addr),
        .o_wr_data    (o_wr_data),
        .o_wr_be      (o_wr_be),

        // post_process Final Scalar -> result_buf
        .i_final_data (pp_final_data),
        .i_final_valid(pp_final_valid),
        .o_final_ready(pp_final_ready),

        // Final Tile Completion
        .o_final_tile_done(result_final_tile_done),

        // Layer Done / CSR / IRQ
        .o_layer_done  (o_layer_done),
        .i_irq_en      (i_irq_en),
        .i_irq_clear   (i_irq_clear),
        .o_final_result(o_final_result),
        .o_done_status (o_done_status),
        .o_irq         (o_irq)
    );

    assign o_tile_in_done = pool_tile_in_done | result_final_tile_done;

endmodule

module output_fifo (
    input logic clk,
    input logic rst_n,

    // Tile configuration
    input logic        i_cfg_valid,
    input logic [11:0] i_patch_base,
    input logic [ 4:0] i_out_ch_base,
    input logic [ 2:0] i_row_mask,
    input logic [ 2:0] i_col_mask,
    input logic        i_tile_last,

    input logic       i_is_fc,
    input logic [6:0] i_conv_w,

    // PE result input
    input logic [287:0] i_result_data,
    input logic [  8:0] i_result_valid,

    // Tile configuration handshake
    output logic o_cfg_ready,

    // PE result space status
    output logic o_result_space_ready,

    // Output
    output logic [95:0] o_data,
    output logic        o_valid,
    input  logic        i_ready,

    output logic [ 2:0] o_keep,
    output logic [18:0] o_meta
);

    // result save register
    logic [95:0] row0_data;
    logic [95:0] row1_data;
    logic [95:0] row2_data;

    logic [ 2:0] row0_valid;
    logic [ 2:0] row1_valid;
    logic [ 2:0] row2_valid;

    // tile set register
    logic [11:0] patch_base_reg;
    logic [ 4:0] out_ch_base_reg;
    logic [ 2:0] row_mask_reg;
    logic [ 2:0] col_mask_reg;
    logic        tile_last_reg;
    logic        is_fc_reg;
    logic [ 6:0] conv_w_reg;
    logic [ 2:0] conv_w_sh_reg;   // log2(conv_w), W is a power of 2

    // log2 via leading-1 position (shift instead of divide)
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

    logic        tile_active;
    logic [ 1:0] out_row;

    logic        cfg_fire;
    logic        out_fire;

    assign o_cfg_ready          = rst_n && !tile_active;
    assign o_result_space_ready = rst_n && !tile_active;

    logic cfg_mask_valid;

    assign cfg_mask_valid =
    (
        (i_row_mask == 3'b001) ||
        (i_row_mask == 3'b011) ||
        (i_row_mask == 3'b111)
    ) &&
    (
        (i_col_mask == 3'b001) ||
        (i_col_mask == 3'b011) ||
        (i_col_mask == 3'b111)
    );
    assign cfg_fire = i_cfg_valid && o_cfg_ready && cfg_mask_valid;
    assign out_fire = o_valid && i_ready;

    logic [1:0] first_row;

    always_comb begin
        first_row = 2'd3;

        if (i_row_mask[0]) begin
            first_row = 2'd0;
        end else if (i_row_mask[1]) begin
            first_row = 2'd1;
        end else if (i_row_mask[2]) begin
            first_row = 2'd2;
        end
    end

    logic [1:0] next_row;

    always_comb begin
        next_row = 2'd3;

        case (out_row)
            2'd0: begin
                if (row_mask_reg[1]) next_row = 2'd1;
                else if (row_mask_reg[2]) next_row = 2'd2;
            end
            2'd1: begin
                if (row_mask_reg[2]) next_row = 2'd2;
            end
            2'd2: begin
                next_row = 2'd3;
            end
            default: begin
                next_row = 2'd3;
            end
        endcase
    end

    logic row0_complete;
    logic row1_complete;
    logic row2_complete;

    assign row0_complete = row_mask_reg[0] && ((row0_valid & col_mask_reg) == col_mask_reg);
    assign row1_complete = row_mask_reg[1] && ((row1_valid & col_mask_reg) == col_mask_reg);
    assign row2_complete = row_mask_reg[2] && ((row2_valid & col_mask_reg) == col_mask_reg);

    logic last_valid_row;

    logic last_valid_0;
    assign last_valid_0 = (out_row == 2'd0) && row_mask_reg[0] && !row_mask_reg[1] && !row_mask_reg[2];
    logic last_valid_1;
    assign last_valid_1 = (out_row == 2'd1) && row_mask_reg[1] && !row_mask_reg[2];
    logic last_valid_2;
    assign last_valid_2 = (out_row == 2'd2) && row_mask_reg[2];

    assign last_valid_row = last_valid_0 || last_valid_1 || last_valid_2;

    logic [95:0] selected_row_data;
    logic        selected_row_complete;

    always_comb begin
        selected_row_data     = 96'd0;
        selected_row_complete = 1'b0;

        case (out_row)
            2'd0: begin
                selected_row_data     = row0_data;
                selected_row_complete = row0_complete;
            end
            2'd1: begin
                selected_row_data     = row1_data;
                selected_row_complete = row1_complete;
            end
            2'd2: begin
                selected_row_data     = row2_data;
                selected_row_complete = row2_complete;
            end
            default: begin
                selected_row_data     = 96'd0;
                selected_row_complete = 1'b0;
            end
        endcase
    end

    always_comb begin
        o_data  = 96'd0;
        o_keep  = 3'b000;
        o_valid = 1'b0;

        if (tile_active && selected_row_complete) begin
            o_keep  = col_mask_reg;
            o_valid = 1'b1;

            case (col_mask_reg)
                3'b001: begin
                    o_data = {64'd0, selected_row_data[31:0]};
                end
                3'b011: begin
                    o_data = {32'd0, selected_row_data[63:0]};
                end
                3'b111: begin
                    o_data = selected_row_data;
                end
                default: begin
                    o_data  = 96'd0;
                    o_keep  = 3'b000;
                    o_valid = 1'b0;
                end
            endcase
        end
    end

    logic [11:0] current_position;

    // Patch index is 2x2-block Z order; convert to pixel position y*W + x
    logic [11:0] cur_patch;
    assign cur_patch = patch_base_reg + {10'd0, out_row};
    logic [ 9:0] blk;
    assign blk       = cur_patch[11:2];                                   // 2x2 block index
    logic [ 1:0] q;
    assign q         = cur_patch[1:0];                                    // (x,y): 0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1)
    logic [ 2:0] wpr_sh;
    assign wpr_sh    = (conv_w_sh_reg == 3'd0) ? 3'd0 : (conv_w_sh_reg - 3'd1);   // log2(W/2)
    logic [ 9:0] by;
    assign by        = blk >> wpr_sh;
    logic [ 9:0] bx;
    assign bx        = blk & ((10'd1 << wpr_sh) - 10'd1);
    logic [11:0] pos_y;
    assign pos_y     = {1'b0, by, 1'b0} + {11'd0, q[1]};
    logic [11:0] pos_x;
    assign pos_x     = {1'b0, bx, 1'b0} + {11'd0, q[0]};

    assign current_position = is_fc_reg ? 12'd0 : ((pos_y << conv_w_sh_reg) | pos_x);
    assign o_meta = {
        tile_last_reg && last_valid_row,  // [18] layer_end
        last_valid_row,  // [17] tile_end
        out_ch_base_reg,  // [16:12] out_ch_base
        current_position  // [11:0] position
    };

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row0_data       <= 96'd0;
            row1_data       <= 96'd0;
            row2_data       <= 96'd0;

            row0_valid      <= 3'b000;
            row1_valid      <= 3'b000;
            row2_valid      <= 3'b000;

            patch_base_reg  <= 12'd0;
            out_ch_base_reg <= 5'd0;
            row_mask_reg    <= 3'b000;
            col_mask_reg    <= 3'b000;
            tile_last_reg   <= 1'b0;
            is_fc_reg       <= 1'b0;
            conv_w_reg      <= 7'd0;
            conv_w_sh_reg   <= 3'd0;

            tile_active     <= 1'b0;
            out_row         <= 2'd0;
        end else begin
            if (cfg_fire) begin
                patch_base_reg  <= i_patch_base;
                out_ch_base_reg <= i_out_ch_base;
                row_mask_reg    <= i_row_mask;
                col_mask_reg    <= i_col_mask;
                tile_last_reg   <= i_tile_last;
                is_fc_reg       <= i_is_fc;
                conv_w_reg      <= i_conv_w;
                conv_w_sh_reg   <= f_log2_7(i_conv_w);

                tile_active     <= 1'b1;

                out_row         <= first_row;

                row0_valid      <= 3'b000;
                row1_valid      <= 3'b000;
                row2_valid      <= 3'b000;
            end else begin
                if (tile_active) begin
                    //row 0
                    if (i_result_valid[0]) begin
                        row0_data[31:0] <= i_result_data[31:0];
                        row0_valid[0]   <= 1'b1;
                    end
                    if (i_result_valid[1]) begin
                        row0_data[63:32] <= i_result_data[63:32];
                        row0_valid[1]    <= 1'b1;
                    end
                    if (i_result_valid[2]) begin
                        row0_data[95:64] <= i_result_data[95:64];
                        row0_valid[2]    <= 1'b1;
                    end

                    //row 1
                    if (i_result_valid[3]) begin
                        row1_data[31:0] <= i_result_data[127:96];
                        row1_valid[0]   <= 1'b1;
                    end
                    if (i_result_valid[4]) begin
                        row1_data[63:32] <= i_result_data[159:128];
                        row1_valid[1]    <= 1'b1;
                    end
                    if (i_result_valid[5]) begin
                        row1_data[95:64] <= i_result_data[191:160];
                        row1_valid[2]    <= 1'b1;
                    end

                    // row 2
                    if (i_result_valid[6]) begin
                        row2_data[31:0] <= i_result_data[223:192];
                        row2_valid[0]   <= 1'b1;
                    end
                    if (i_result_valid[7]) begin
                        row2_data[63:32] <= i_result_data[255:224];
                        row2_valid[1]    <= 1'b1;
                    end
                    if (i_result_valid[8]) begin
                        row2_data[95:64] <= i_result_data[287:256];
                        row2_valid[2]    <= 1'b1;
                    end
                end

                // output handshake
                if (out_fire) begin
                    case (out_row)
                        2'd0: row0_valid <= 3'b000;
                        2'd1: row1_valid <= 3'b000;
                        2'd2: row2_valid <= 3'b000;
                        default: begin
                            row0_valid <= row0_valid;
                            row1_valid <= row1_valid;
                            row2_valid <= row2_valid;
                        end
                    endcase
                    if (last_valid_row) begin
                        tile_active <= 1'b0;
                        out_row     <= 2'd0;
                    end else begin
                        out_row <= next_row;
                    end
                end
            end
        end
    end

endmodule

module param_buf #(
    parameter integer PARAM_TOTAL = 43      // Conv0 6 + Conv1 4 + fc1 32 + fc2 1
) (
    input  logic        clk,
    input  logic        rst_n,

    // cnn_cntl -> out_path
    input  logic               i_load_start,
    input  logic               i_wr_en,
    input  logic        [ 5:0] i_wr_addr,
    input  logic signed [31:0] i_wr_data,
    output logic               o_load_done,
    output logic               o_loaded,

    // -> post_process
    input  logic               i_rd_req_valid,
    output logic               o_rd_req_ready,
    input  logic        [ 5:0] i_rd_addr,
    output logic signed [31:0] o_rd_data,
    output logic               o_rd_rsp_valid,
    input  logic               i_rd_rsp_ready
);

    logic signed [31:0] mem [0:63];                // only 0..42 used
    logic        loading;                     // high from load_start to last store
    logic [ 5:0] wr_cnt;

    logic wr_fire;
    assign wr_fire = loading && !i_load_start && i_wr_en;
    logic wr_last;
    assign wr_last   = wr_fire && (wr_cnt == PARAM_TOTAL - 1);
    logic req_fire;
    assign req_fire  = i_rd_req_valid && o_rd_req_ready;
    logic rsp_fire;
    assign rsp_fire  = o_rd_rsp_valid && i_rd_rsp_ready;

    // Ready again in the same clock the response is taken (back-to-back reads)
    assign o_rd_req_ready = o_loaded && !loading && !i_load_start && (!o_rd_rsp_valid || i_rd_rsp_ready);

    always_ff @(posedge clk) begin
        if (wr_fire)  mem[i_wr_addr] <= i_wr_data;
        if (req_fire) o_rd_data      <= mem[i_rd_addr];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loading        <= 1'b0;
            wr_cnt         <= 6'd0;
            o_load_done    <= 1'b0;
            o_loaded       <= 1'b0;
            o_rd_rsp_valid <= 1'b0;
        end else begin
            o_load_done <= 1'b0;

            if (i_load_start) begin
                loading        <= 1'b1;
                wr_cnt         <= 6'd0;
                o_loaded       <= 1'b0;
                o_rd_rsp_valid <= 1'b0;
            end else if (wr_fire) begin
                wr_cnt <= wr_cnt + 6'd1;
                if (wr_last) begin
                    loading     <= 1'b0;
                    o_loaded    <= 1'b1;
                    o_load_done <= 1'b1;
                end
            end

            if      (req_fire)      o_rd_rsp_valid <= 1'b1;
            else if (rsp_fire)      o_rd_rsp_valid <= 1'b0;
        end
    end

endmodule

module post_process (
    input logic clk,
    input logic rst_n,

    // Tile / Layer Configuration
    input logic i_cfg_valid,
    output logic o_cfg_ready,

    input logic [2:0] i_col_mask,
    input logic [4:0] i_out_ch_base,

    input logic [5:0] i_bias_base,
    input logic       i_relu_en,
    input logic       i_is_final_layer,

    input logic signed [31:0] i_quant_multiplier,
    input logic        [ 5:0] i_quant_shift,

    input logic signed [31:0] i_angle_multiplier,
    input logic        [ 5:0] i_angle_shift,

    // Parameter Buffer Interface
    input  logic i_params_loaded,
    output logic o_params_ready,

    // Bias Read Request
    output logic       o_bias_req_valid,
    input  logic       i_bias_req_ready,
    output logic [5:0] o_bias_addr,

    // Bias Read Response
    input  logic signed [31:0] i_bias_data,
    input  logic               i_bias_rsp_valid,
    output logic               o_bias_rsp_ready,

    // Input Stream from Output FIFO
    input  logic [95:0] i_data,
    input  logic        i_valid,
    output logic        o_ready,

    input logic [ 2:0] i_keep,
    input logic [18:0] i_meta,

    // Normal Output Stream to Pooling Unit (3 lanes x INT8)
    output logic [23:0] o_data,
    output logic        o_valid,
    input  logic        i_ready,

    output logic [ 2:0] o_keep,
    output logic [18:0] o_meta,

    // Final Layer Output to Result Buffer
    output logic signed [7:0] o_final_data,
    output logic              o_final_valid,
    input  logic              i_final_ready
);
    // ---- config registers ----
    logic [2:0] col_mask_reg;          // 001/011/111 = lanes 0 / 0-1 / 0-2
    logic [4:0] out_ch_base_reg;
    logic [5:0] bias_base_reg;         // bias addr = base + out_ch_base + lane
    logic relu_en_reg;
    logic is_final_layer_reg;
    logic signed [31:0] quant_multiplier_reg;
    logic        [ 5:0] quant_shift_reg;
    logic signed [31:0] angle_multiplier_reg;   // final INT32 -> INT8 angle
    logic        [ 5:0] angle_shift_reg;
    logic cfg_change_allowed;

    // ---- bias cache ----
    // Biases for the current tile, read once at tile setup
    logic signed [31:0] bias_cache0;
    logic signed [31:0] bias_cache1;
    logic signed [31:0] bias_cache2;

    // Bias requests issued back-to-back; responses taken as they arrive (ready always 1)
    logic [1:0] bias_req_idx;      // next lane to request
    logic [1:0] bias_rsp_idx;      // next lane to receive
    logic [1:0] bias_n_lanes;      // lanes needed: 1/2/3

    // 2-entry cache keyed by (bias_base, out_ch_base, col_mask); hit skips param_buf read.
    // Cleared when params reload (i_params_loaded=0).
    logic        [ 1:0] bc_valid;
    logic        [13:0] bc_key0, bc_key1;           // {bias_base, out_ch_base, col_mask}
    logic signed [31:0] bc0_b0, bc0_b1, bc0_b2;
    logic signed [31:0] bc1_b0, bc1_b1, bc1_b2;
    logic               bc_next;                    // next entry to fill
    logic        [13:0] cfg_key;
    assign cfg_key  = {i_bias_base, i_out_ch_base, i_col_mask};
    logic               cfg_hit0;
    assign cfg_hit0 = bc_valid[0] && (bc_key0 == cfg_key);
    logic               cfg_hit1;
    assign cfg_hit1 = bc_valid[1] && (bc_key1 == cfg_key);
    logic               cfg_hit;
    assign cfg_hit  = cfg_hit0 || cfg_hit1;

    // ---- input beat buffer (lanes processed one at a time) ----
    logic [95:0] data_reg;
    logic [2:0] keep_reg;
    logic [18:0] meta_reg;          // passed downstream unchanged

    logic signed [31:0] lane0_data;
    logic signed [31:0] lane1_data;
    logic signed [31:0] lane2_data;

    assign lane0_data = $signed(data_reg[31:0]);
    assign lane1_data = $signed(data_reg[63:32]);
    assign lane2_data = $signed(data_reg[95:64]);

    // ---- lane select (3 lanes share one requant unit) ----
    logic [1:0] lane_idx;
    logic signed [31:0] current_lane_data;
    logic signed [31:0] current_bias;
    logic current_lane_valid;

    always_comb begin
        current_lane_data  = 32'd0;
        current_bias       = 32'd0;
        current_lane_valid = 1'b0;

        case (lane_idx)

            2'd0: begin
                current_lane_data  = lane0_data;
                current_bias       = bias_cache0;
                current_lane_valid = keep_reg[0];
            end

            2'd1: begin
                current_lane_data  = lane1_data;
                current_bias       = bias_cache1;
                current_lane_valid = keep_reg[1];
            end

            2'd2: begin
                current_lane_data  = lane2_data;
                current_bias       = bias_cache2;
                current_lane_valid = keep_reg[2];
            end

            default: begin
                current_lane_data  = 32'd0;
                current_bias       = 32'd0;
                current_lane_valid = 1'b0;
            end
        endcase
    end

    // ---- requant pipeline: 4 stages, one lane issued per clock in PROCESS ----
    // Result written to result_lane 3 clocks after issue; one beat = lanes + 3 clocks.

    // s0: bias add + INT32 saturation (combinational)
    logic signed [32:0] bias_sum_ext;   // 33 bits to detect overflow
    logic signed [31:0] acc32_reg;      // A32 in the golden model

    always_comb begin
        bias_sum_ext = {current_lane_data[31], current_lane_data} + {current_bias[31], current_bias};
    end

    always_comb begin
        case (bias_sum_ext[32:31])
            2'b01:   acc32_reg = 32'h7FFF_FFFF;   // +overflow -> INT32 max
            2'b10:   acc32_reg = 32'h8000_0000;   // -overflow -> INT32 min
            default: acc32_reg = bias_sum_ext[31:0];
        endcase
    end

    // Final layer uses the angle M / S
    logic signed [31:0] current_multiplier;
    logic        [ 5:0] current_shift;

    always_comb begin
        if (is_final_layer_reg) begin
            current_multiplier = angle_multiplier_reg;
            current_shift      = angle_shift_reg;
        end
        else begin
            current_multiplier = quant_multiplier_reg;
            current_shift      = quant_shift_reg;
        end
    end

    // s1: acc32, M (DSP input regs); s2: 64-bit product; s3: product + round offset, then shift + saturate
    logic               s1_valid, s2_valid, s3_valid;
    logic        [ 1:0] s1_lane,  s2_lane,  s3_lane;
    logic               s1_last,  s2_last,  s3_last;    // last lane of this beat
    logic signed [31:0] s1_acc32;
    logic signed [31:0] s1_mult;
    logic signed [63:0] s2_prod;
    logic signed [63:0] s3_sum;

    // Round to nearest, ties away from zero: P>=0 add 2^(S-1), P<0 add 2^(S-1)-1, then >>> S
    logic        [63:0] round_half;
    assign round_half = (current_shift == 6'd0) ? 64'd0 : (64'd1 << (current_shift - 6'd1));
    logic signed [63:0] round_off;
    assign round_off  = (current_shift == 6'd0) ? 64'sd0 :
                        (s2_prod[63] ? ($signed(round_half) - 64'sd1) : $signed(round_half));

    logic signed [63:0] rounded_result;
    assign rounded_result = s3_sum >>> current_shift;

    // Normal layer: ReLU + INT8 saturation
    logic signed [7:0] normal_int8_result;

    always_comb begin
        if (relu_en_reg && rounded_result[63])        normal_int8_result = 8'd0;
        else if (rounded_result > $signed(64'd127))   normal_int8_result = 8'h7F;
        else if (rounded_result < -$signed(64'd128))  normal_int8_result = 8'h80;
        else                                          normal_int8_result = rounded_result[7:0];
    end

    // Final FC2: INT8 saturation, no ReLU (angle in degrees)
    logic signed [7:0] final_int8_result;

    always_comb begin
        if (rounded_result > $signed(64'd127))        final_int8_result = 8'h7F;
        else if (rounded_result < -$signed(64'd128))  final_int8_result = 8'h80;
        else                                          final_int8_result = rounded_result[7:0];
    end

    logic signed [7:0] final_result_reg;

    // Per-lane INT8 results, packed into o_data
    logic signed [7:0] result_lane0;
    logic signed [7:0] result_lane1;
    logic signed [7:0] result_lane2;

    logic issue_done;              // last lane of beat issued, waiting for result

    // ---- FSM ----
    typedef enum logic [2:0] {
        IDLE       = 3'd0, // wait for tile cfg
        BIAS_REQ   = 3'd1, // bias reads in flight
        BIAS_WAIT  = 3'd2, // unused
        READY      = 3'd3, // wait for FIFO input
        PROCESS    = 3'd4, // lanes through requant pipeline
        OUT_WAIT   = 3'd5,
        FINAL_WAIT = 3'd6
    } pp_state_e;

    pp_state_e state;
    pp_state_e next_state;

    // ---- handshakes / cfg checks ----
    logic input_fire;
    logic output_fire;
    logic final_fire;
    logic bias_req_fire;
    logic bias_rsp_fire;
    logic cfg_fire;

    // Normal: 001/011/111; final FC2: 001 only
    logic cfg_mask_valid;

    assign cfg_mask_valid = i_is_final_layer ? (i_col_mask == 3'b001) :
            ((i_col_mask == 3'b001) ||
             (i_col_mask == 3'b011) ||
             (i_col_mask == 3'b111));

    logic [6:0] cfg_bias_last_addr;
    logic cfg_bias_addr_valid;     // last bias addr <= 42

    // FC2: 1 output channel, bias addr 42, no ReLU
    logic cfg_final_valid;

    assign cfg_final_valid = !i_is_final_layer || (
            (i_out_ch_base == 5'd0) &&
            (i_bias_base   == 6'd42) &&
            (i_relu_en     == 1'b0));

    assign cfg_bias_last_addr = {1'b0, i_bias_base} + {2'b00, i_out_ch_base} +
        ((i_col_mask == 3'b111) ? 7'd2 : (i_col_mask == 3'b011) ? 7'd1 : 7'd0);

    assign cfg_bias_addr_valid = (cfg_bias_last_addr <= 7'd42);

    logic input_keep_valid;
    logic final_input_valid;   // FC2: lane0 only, tile_end + layer_end
    logic input_meta_valid;

    assign input_meta_valid = (i_meta[16:12] == out_ch_base_reg) && (!i_meta[18] || i_meta[17]);

    assign final_input_valid = !is_final_layer_reg || ((i_keep    == 3'b001) && (i_meta[17] == 1'b1) && (i_meta[18] == 1'b1));
    assign input_keep_valid = ((i_keep == 3'b001) || (i_keep == 3'b011) || (i_keep == 3'b111)) && (i_keep == col_mask_reg);

    assign cfg_fire = i_cfg_valid && o_cfg_ready;
    assign o_cfg_ready =
        i_params_loaded &&
        cfg_mask_valid &&
        cfg_bias_addr_valid &&
        cfg_final_valid &&
        cfg_change_allowed &&
        ((state == IDLE) || (state == READY));

    assign input_fire    = i_valid          && o_ready;
    assign output_fire   = o_valid          && i_ready;
    assign final_fire    = o_final_valid    && i_final_ready;
    assign bias_req_fire = o_bias_req_valid && i_bias_req_ready;
    assign bias_rsp_fire = i_bias_rsp_valid && o_bias_rsp_ready;

    logic bias_rsp_last;
    assign bias_rsp_last = bias_rsp_fire && (bias_rsp_idx == bias_n_lanes - 2'd1);

    // ---- lane issue / completion ----
    // keep is contiguous from lane0
    logic [1:0] last_lane_idx;
    assign last_lane_idx = keep_reg[2] ? 2'd2 : (keep_reg[1] ? 2'd1 : 2'd0);

    logic       issue_last;    // last lane issued into s0 this clock
    assign issue_last    = (state == PROCESS) && !issue_done && (lane_idx == last_lane_idx);

    logic       process_done;  // last lane written at s3
    assign process_done  = (state == PROCESS) && s3_last;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;

        case (state)
            IDLE: begin
                if (cfg_fire)
                    next_state = cfg_hit ? READY : BIAS_REQ;   // cache hit skips bias read
            end

            BIAS_REQ: begin
                if (bias_rsp_last)
                    next_state = READY;
            end

            BIAS_WAIT: begin
                next_state = READY;
            end

            READY: begin
                if (cfg_fire) begin
                    next_state = cfg_hit ? READY : BIAS_REQ;
                end
                else if (input_fire) begin
                    next_state = PROCESS;
                end
            end

            PROCESS: begin
                if (process_done) begin
                    if (is_final_layer_reg)
                        next_state = FINAL_WAIT;
                    else
                        next_state = OUT_WAIT;
                end
            end

            OUT_WAIT: begin
                if (output_fire)
                    next_state = READY;
            end

            FINAL_WAIT: begin
                if (final_fire)
                    next_state = READY;
            end

            default: begin
                next_state = IDLE;
            end

        endcase
    end

    always_comb begin
        o_params_ready   = 1'b0;

        o_bias_req_valid = 1'b0;
        o_bias_addr      = 6'd0;
        o_bias_rsp_ready = 1'b0;

        o_ready          = 1'b0;

        // Data driven from regs without state gating (timing); only valid is gated
        o_data           = {result_lane2, result_lane1, result_lane0};
        o_valid          = 1'b0;
        o_keep           = keep_reg;
        o_meta           = meta_reg;
        o_final_data     = final_result_reg;
        o_final_valid    = 1'b0;

        case (state)

            IDLE: begin
            end

            BIAS_REQ: begin
                o_bias_req_valid = (bias_req_idx < bias_n_lanes);
                o_bias_addr      = bias_base_reg + out_ch_base_reg + bias_req_idx;
                o_bias_rsp_ready = 1'b1;
            end

            BIAS_WAIT: begin
            end

            READY: begin
                o_params_ready = 1'b1;
                // Not in the cfg-accept cycle; a valid beat must pass keep/meta checks
                o_ready = !cfg_change_allowed && !cfg_fire && (!i_valid || (input_keep_valid && input_meta_valid && final_input_valid));
            end

            PROCESS: begin
                o_params_ready = 1'b1;
            end

            OUT_WAIT: begin
                o_params_ready = 1'b1;
                o_data  = {result_lane2, result_lane1, result_lane0};
                o_keep  = keep_reg;
                o_meta  = meta_reg;
                o_valid = 1'b1;
            end

            FINAL_WAIT: begin
                o_params_ready = 1'b1;
                o_final_data  = final_result_reg;
                o_final_valid = 1'b1;
            end

            default: begin
            end

        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_mask_reg         <= 3'b000;
            out_ch_base_reg      <= 5'd0;
            bias_base_reg        <= 6'd0;
            relu_en_reg          <= 1'b0;
            is_final_layer_reg   <= 1'b0;

            quant_multiplier_reg <= 32'd0;
            quant_shift_reg      <= 6'd0;

            angle_multiplier_reg <= 32'd0;
            angle_shift_reg      <= 6'd0;
        end
        else if (cfg_fire) begin
            col_mask_reg         <= i_col_mask;
            out_ch_base_reg      <= i_out_ch_base;
            bias_base_reg        <= i_bias_base;
            relu_en_reg          <= i_relu_en;
            is_final_layer_reg   <= i_is_final_layer;

            quant_multiplier_reg <= i_quant_multiplier;
            quant_shift_reg      <= i_quant_shift;

            angle_multiplier_reg <= i_angle_multiplier;
            angle_shift_reg      <= i_angle_shift;
        end
    end

    // Tile cfg lock: closed on cfg accept, reopened when the tile's last output is taken
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_change_allowed <= 1'b1;
        end
        else if (cfg_fire) begin
            cfg_change_allowed <= 1'b0;
        end
        else if (output_fire && meta_reg[17]) begin
            cfg_change_allowed <= 1'b1;
        end
        else if (final_fire) begin
            cfg_change_allowed <= 1'b1;
        end
    end

    // ---- bias read / cache update ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bias_cache0   <= 32'd0;
            bias_cache1   <= 32'd0;
            bias_cache2   <= 32'd0;
            bias_req_idx  <= 2'd0;
            bias_rsp_idx  <= 2'd0;
            bias_n_lanes  <= 2'd1;
            bc_valid      <= 2'b00;
            bc_key0       <= 14'd0;  bc_key1 <= 14'd0;
            bc0_b0 <= 32'd0; bc0_b1 <= 32'd0; bc0_b2 <= 32'd0;
            bc1_b0 <= 32'd0; bc1_b1 <= 32'd0; bc1_b2 <= 32'd0;
            bc_next       <= 1'b0;
        end
        else begin
            if (!i_params_loaded) bc_valid <= 2'b00;

            if (cfg_fire) begin
                bias_req_idx <= 2'd0;
                bias_rsp_idx <= 2'd0;
                bias_n_lanes <= i_col_mask[2] ? 2'd3 : (i_col_mask[1] ? 2'd2 : 2'd1);
                if (cfg_hit0) begin
                    bias_cache0 <= bc0_b0;  bias_cache1 <= bc0_b1;  bias_cache2 <= bc0_b2;
                end
                else if (cfg_hit1) begin
                    bias_cache0 <= bc1_b0;  bias_cache1 <= bc1_b1;  bias_cache2 <= bc1_b2;
                end
                else begin
                    bias_cache0 <= 32'd0;   bias_cache1 <= 32'd0;   bias_cache2 <= 32'd0;
                end
            end
            else begin
                if (bias_req_fire) bias_req_idx <= bias_req_idx + 2'd1;
                if (bias_rsp_fire) begin
                    bias_rsp_idx <= bias_rsp_idx + 2'd1;
                    case (bias_rsp_idx)
                        2'd0:    bias_cache0 <= i_bias_data;
                        2'd1:    bias_cache1 <= i_bias_data;
                        default: bias_cache2 <= i_bias_data;
                    endcase
                end
                // Last response: fill cache entry bc_next
                if (bias_rsp_last && i_params_loaded) begin
                    if (!bc_next) begin
                        bc_key0 <= {bias_base_reg, out_ch_base_reg, col_mask_reg};
                        bc0_b0  <= (bias_rsp_idx == 2'd0) ? i_bias_data : bias_cache0;
                        bc0_b1  <= (bias_rsp_idx == 2'd1) ? i_bias_data : bias_cache1;
                        bc0_b2  <= (bias_rsp_idx == 2'd2) ? i_bias_data : bias_cache2;
                        bc_valid[0] <= 1'b1;
                    end
                    else begin
                        bc_key1 <= {bias_base_reg, out_ch_base_reg, col_mask_reg};
                        bc1_b0  <= (bias_rsp_idx == 2'd0) ? i_bias_data : bias_cache0;
                        bc1_b1  <= (bias_rsp_idx == 2'd1) ? i_bias_data : bias_cache1;
                        bc1_b2  <= (bias_rsp_idx == 2'd2) ? i_bias_data : bias_cache2;
                        bc_valid[1] <= 1'b1;
                    end
                    bc_next <= ~bc_next;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= 96'd0;
            keep_reg <= 3'b000;
            meta_reg <= 19'd0;
        end
        else if (input_fire) begin
            data_reg <= i_data;
            keep_reg <= i_keep;
            meta_reg <= i_meta;
        end
    end

    // ---- lane pipeline advance ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lane_idx         <= 2'd0;
            issue_done       <= 1'b0;
            s1_valid <= 1'b0;  s2_valid <= 1'b0;  s3_valid <= 1'b0;
            s1_lane  <= 2'd0;  s2_lane  <= 2'd0;  s3_lane  <= 2'd0;
            s1_last  <= 1'b0;  s2_last  <= 1'b0;  s3_last  <= 1'b0;
            s1_acc32 <= 32'd0; s1_mult  <= 32'd0;
            s2_prod  <= 64'd0; s3_sum   <= 64'd0;
            result_lane0     <= 8'd0;
            result_lane1     <= 8'd0;
            result_lane2     <= 8'd0;
            final_result_reg <= 8'd0;
        end
        else begin
            // s0 -> s1: invalid lanes pass through with valid=0
            s1_valid <= (state == PROCESS) && !issue_done && current_lane_valid;
            s1_lane  <= lane_idx;
            s1_last  <= issue_last;
            s1_acc32 <= acc32_reg;
            s1_mult  <= current_multiplier;

            // s1 -> s2: 32x32 multiply (DSP)
            s2_valid <= s1_valid;
            s2_lane  <= s1_lane;
            s2_last  <= s1_last;
            s2_prod  <= s1_acc32 * s1_mult;

            // s2 -> s3: add rounding offset
            s3_valid <= s2_valid;
            s3_lane  <= s2_lane;
            s3_last  <= s2_last;
            s3_sum   <= s2_prod + round_off;

            // s3: store shifted + saturated result
            if (s3_valid) begin
                if (!is_final_layer_reg) begin
                    case (s3_lane)
                        2'd0:    result_lane0 <= normal_int8_result;
                        2'd1:    result_lane1 <= normal_int8_result;
                        2'd2:    result_lane2 <= normal_int8_result;
                        default: begin end
                    endcase
                end
                else if (s3_lane == 2'd0) begin
                    final_result_reg <= final_int8_result;
                end
            end

            // New beat: restart at lane0, clear stale results in unused lanes
            if (input_fire) begin
                lane_idx         <= 2'd0;
                issue_done       <= 1'b0;
                result_lane0     <= 8'd0;
                result_lane1     <= 8'd0;
                result_lane2     <= 8'd0;
                final_result_reg <= 8'd0;
            end
            else if ((state == PROCESS) && !issue_done) begin
                if (issue_last) issue_done <= 1'b1;
                else            lane_idx   <= lane_idx + 2'd1;
            end
        end
    end

endmodule

module pooling_unit (
    input logic clk,
    input logic rst_n,

    // Layer Configuration
    input logic       i_cfg_valid,
    input logic       i_pool_en,
    input logic [6:0] i_in_w,
    input logic [6:0] i_in_h,
    input logic [5:0] i_channels,

    // Input Stream from post_process
    input  logic [23:0] i_data,
    input  logic        i_valid,
    output logic        o_ready,

    input logic [ 2:0] i_keep,
    input logic [18:0] i_meta,

    // Output Stream to result_buf
    output logic [23:0] o_data,
    output logic        o_valid,
    input  logic        i_ready,

    output logic [ 2:0] o_keep,
    output logic [18:0] o_meta,

    output logic o_tile_in_done
);

    // ---- layer config registers ----
    logic       pool_en_reg;
    logic [6:0] in_w_reg;
    logic [6:0] in_h_reg;
    logic [5:0] channels_reg;
    logic [2:0] in_w_sh_reg;     // log2(in_w), in_w is a power of 2
    logic [6:0] in_w_mask_reg;   // in_w - 1

    // log2 via leading-1 position (shift instead of divide)
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pool_en_reg   <= 1'b0;
            in_w_reg      <= 7'd0;
            in_h_reg      <= 7'd0;
            channels_reg  <= 6'd0;
            in_w_sh_reg   <= 3'd0;
            in_w_mask_reg <= 7'd0;
        end else if (i_cfg_valid) begin
            pool_en_reg   <= i_pool_en;
            in_w_reg      <= i_in_w;
            in_h_reg      <= i_in_h;
            channels_reg  <= i_channels;
            in_w_sh_reg   <= f_log2_7(i_in_w);
            in_w_mask_reg <= i_in_w - 7'd1;
        end
    end

    // meta: [18] layer_end, [17] tile_end, [16:12] out_ch_base, [11:0] position
    logic [11:0] input_pos;
    logic [ 4:0] input_out_ch_base;
    logic        input_tile_end;
    logic        input_layer_end;

    assign input_pos         = i_meta[11:0];
    assign input_out_ch_base = i_meta[16:12];
    assign input_tile_end    = i_meta[17];
    assign input_layer_end   = i_meta[18];

    // Channel group: 0 = ch 0-2, 1 = ch 3-5. Declared here so it precedes its use.
    logic pool_group_sel;

    assign pool_group_sel = (input_out_ch_base == 5'd3);

    // ---- position decode: pos = y * in_w + x ----
    logic [11:0] input_y_full;
    logic [11:0] input_x_full;

    // shift / mask instead of division (timing)
    assign input_y_full = input_pos >> in_w_sh_reg;
    assign input_x_full = input_pos & {5'd0, in_w_mask_reg};

    logic [6:0] input_y;
    logic [6:0] input_x;

    assign input_y = input_y_full[6:0];
    assign input_x = input_x_full[6:0];

    // ---- 2x2 window ----
    // q: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right
    logic [1:0] pool_q;

    assign pool_q = {input_y[0], input_x[0]};

    // pool_pos = (y/2) * (in_w/2) + (x/2), done with shift / OR
    logic [11:0] pool_position;

    logic [11:0] pool_y2;
    assign pool_y2 = {6'd0, input_y[6:1]};
    logic [11:0] pool_x2;
    assign pool_x2 = {6'd0, input_x[6:1]};
    assign pool_position = (in_w_sh_reg == 3'd0) ? 12'd0 : ((pool_y2 << (in_w_sh_reg - 3'd1)) | pool_x2);

    logic [11:0] pool_window_id;

    assign pool_window_id = pool_position;

    // ---- handshake / output register ----
    logic [23:0] out_data_reg;
    logic        out_valid_reg;
    logic [ 2:0] out_keep_reg;
    logic [18:0] out_meta_reg;

    logic        input_fire;
    logic        output_fire;
    logic        pool_state_ready;

    assign o_ready =
        rst_n &&
        !i_cfg_valid &&
        (!out_valid_reg || i_ready) &&
        (!i_valid || pool_state_ready);

    assign input_fire = i_valid && o_ready;
    assign output_fire = out_valid_reg && i_ready;

    assign o_data = out_data_reg;
    assign o_valid = out_valid_reg;
    assign o_keep = out_keep_reg;
    assign o_meta = out_meta_reg;

    logic signed [7:0] input_lane0;
    logic signed [7:0] input_lane1;
    logic signed [7:0] input_lane2;

    assign input_lane0 = $signed(i_data[7:0]);
    assign input_lane1 = $signed(i_data[15:8]);
    assign input_lane2 = $signed(i_data[23:16]);

    // ---- group 0 pool state (ch 0-2) ----
    logic               group0_window_valid;   // window in progress
    logic        [11:0] group0_window_id;
    logic        [ 1:0] group0_next_q;         // expected q: 0->1->2->3
    logic signed [ 7:0] group0_max0;
    logic signed [ 7:0] group0_max1;
    logic signed [ 7:0] group0_max2;
    logic [2:0] group0_keep_reg;

    // ---- group 1 pool state (ch 3-5) ----
    logic               group1_window_valid;
    logic        [11:0] group1_window_id;
    logic        [ 1:0] group1_next_q;

    logic signed [ 7:0] group1_max0;
    logic signed [ 7:0] group1_max1;
    logic signed [ 7:0] group1_max2;
    logic [2:0] group1_keep_reg;

    // Final max including the q=3 input
    logic signed [7:0] group0_final_max0;
    logic signed [7:0] group0_final_max1;
    logic signed [7:0] group0_final_max2;

    logic signed [7:0] group1_final_max0;
    logic signed [7:0] group1_final_max1;
    logic signed [7:0] group1_final_max2;

    assign group0_final_max0 =
        (group0_keep_reg[0] && (input_lane0 > group0_max0)) ?
        input_lane0 : group0_max0;

    assign group0_final_max1 =
        (group0_keep_reg[1] && (input_lane1 > group0_max1)) ?
        input_lane1 : group0_max1;

    assign group0_final_max2 =
        (group0_keep_reg[2] && (input_lane2 > group0_max2)) ?
        input_lane2 : group0_max2;

    assign group1_final_max0 =
        (group1_keep_reg[0] && (input_lane0 > group1_max0)) ?
        input_lane0 : group1_max0;

    assign group1_final_max1 =
        (group1_keep_reg[1] && (input_lane1 > group1_max1)) ?
        input_lane1 : group1_max1;

    assign group1_final_max2 =
        (group1_keep_reg[2] && (input_lane2 > group1_max2)) ?
        input_lane2 : group1_max2;

    // ---- last pool output detection ----
    logic [2:0] input_valid_lane_count;
    logic [6:0] input_group_end_ch;

    logic pool_last_window;
    logic pool_last_group;
    logic pool_output_layer_end;

    assign input_valid_lane_count =
        {2'd0, i_keep[0]} +
        {2'd0, i_keep[1]} +
        {2'd0, i_keep[2]};

    // exclusive end channel (base=3, keep=111 -> 6)
    assign input_group_end_ch =
        {2'd0, input_out_ch_base} +
        {4'd0, input_valid_lane_count};

    assign pool_last_window =
        (in_w_reg != 7'd0) &&
        (in_h_reg != 7'd0) &&
        (input_x == (in_w_reg - 7'd1)) &&
        (input_y == (in_h_reg - 7'd1));

    assign pool_last_group =
        (input_group_end_ch >= {1'b0, channels_reg});

    assign pool_output_layer_end =
        input_layer_end &&
        pool_last_window &&
        pool_last_group;

    // ---- input validity checks ----
    logic input_keep_valid;
    logic input_position_valid;
    logic pool_group_valid;
    logic pool_cfg_valid;
    logic pool_layer_end_valid;

    assign pool_cfg_valid =
        (in_w_reg >= 7'd2) &&
        (in_h_reg >= 7'd2) &&
        (in_w_reg[0] == 1'b0) &&
        (in_h_reg[0] == 1'b0) &&
        ((in_w_reg & (in_w_reg - 7'd1)) == 7'd0) &&   // power of 2 (shift-based position)
        (channels_reg >= 6'd1) &&
        (channels_reg <= 6'd6);

    // layer_end only on q=3 of the last window, last group
    assign pool_layer_end_valid =
        !input_layer_end ||
        (
            (pool_q == 2'd3) &&
            pool_last_window &&
            pool_last_group
        );

    assign input_position_valid =
        (in_w_reg != 7'd0) &&
        (in_h_reg != 7'd0) &&
        (input_y_full < {5'd0, in_h_reg}) &&
        (input_x_full < {5'd0, in_w_reg});

    assign input_keep_valid =
        (i_keep == 3'b001) ||
        (i_keep == 3'b011) ||
        (i_keep == 3'b111);

    // 6-channel MaxPool layer: group base must be 0 or 3
    assign pool_group_valid =
        (input_out_ch_base == 5'd0) ||
        (input_out_ch_base == 5'd3);

    // MaxPool enforces q=0->3 per group: q=0 needs no open window,
    // q=1..3 need matching window_id, next_q and keep.
    assign pool_state_ready =
        !pool_en_reg ?
        (
            input_keep_valid
        )
        :
        (
            input_keep_valid &&
            input_position_valid &&
            pool_group_valid &&
            pool_cfg_valid &&
            pool_layer_end_valid &&
            (
                !pool_group_sel ?
                (
                    (pool_q == 2'd0) ?
                        !group0_window_valid
                    :
                        (
                            group0_window_valid &&
                            (group0_window_id == pool_window_id) &&
                            (group0_next_q == pool_q) &&
                            (group0_keep_reg == i_keep)
                        )
                )
                :
                (
                    (pool_q == 2'd0) ?
                        !group1_window_valid
                    :
                        (
                            group1_window_valid &&
                            (group1_window_id == pool_window_id) &&
                            (group1_next_q == pool_q) &&
                            (group1_keep_reg == i_keep)
                        )
                )
            )
        );

    // ---- output register / tile input done ----
    // Placed after the group*_final_max / pool_output_layer_end declarations (declare before use)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data_reg      <= 24'd0;
            out_valid_reg     <= 1'b0;
            out_keep_reg      <= 3'b000;
            out_meta_reg      <= 19'd0;

            o_tile_in_done    <= 1'b0;
        end
        else begin
            o_tile_in_done <= 1'b0;

            // drop pending output when a new layer starts
            if (i_cfg_valid) begin
                out_valid_reg <= 1'b0;
            end
            else begin

                if (output_fire) begin
                    out_valid_reg <= 1'b0;
                end

                if (input_fire) begin

                    // bypass
                    if (!pool_en_reg) begin
                        out_data_reg  <= i_data;
                        out_keep_reg  <= i_keep;
                        out_meta_reg  <= i_meta;
                        out_valid_reg <= 1'b1;
                    end

                    // 2x2 MaxPool: output only at q=3
                    else if (pool_q == 2'd3) begin

                        if (!pool_group_sel) begin
                            out_data_reg <= {
                                group0_final_max2,
                                group0_final_max1,
                                group0_final_max0
                            };

                            out_keep_reg <= group0_keep_reg;
                        end
                        else begin
                            out_data_reg <= {
                                group1_final_max2,
                                group1_final_max1,
                                group1_final_max0
                            };

                            out_keep_reg <= group1_keep_reg;
                        end

                        // meta: [18] layer_end, [17] tile_end=0, [16:12] out_ch_base, [11:0] pooled pos
                        out_meta_reg <= {
                            pool_output_layer_end,
                            1'b0,
                            input_out_ch_base,
                            pool_position
                        };

                        out_valid_reg <= 1'b1;
                    end

                    if (input_tile_end) begin
                        o_tile_in_done <= 1'b1;
                    end
                end
            end
        end
    end

    // ---- pool state update ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            group0_window_valid <= 1'b0;
            group0_window_id    <= 12'd0;
            group0_next_q       <= 2'd0;

            group0_max0         <= 8'd0;
            group0_max1         <= 8'd0;
            group0_max2         <= 8'd0;

            group1_window_valid <= 1'b0;
            group1_window_id    <= 12'd0;
            group1_next_q       <= 2'd0;

            group1_max0         <= 8'd0;
            group1_max1         <= 8'd0;
            group1_max2         <= 8'd0;
            group0_keep_reg     <= 3'b000;
            group1_keep_reg     <= 3'b000;
        end
        else if (i_cfg_valid) begin
            group0_window_valid <= 1'b0;
            group0_window_id    <= 12'd0;
            group0_next_q       <= 2'd0;

            group0_max0         <= 8'd0;
            group0_max1         <= 8'd0;
            group0_max2         <= 8'd0;

            group1_window_valid <= 1'b0;
            group1_window_id    <= 12'd0;
            group1_next_q       <= 2'd0;

            group1_max0         <= 8'd0;
            group1_max1         <= 8'd0;
            group1_max2         <= 8'd0;
            group0_keep_reg     <= 3'b000;
            group1_keep_reg     <= 3'b000;
        end
        else if (input_fire && pool_en_reg) begin

            // group 0
            if (!pool_group_sel) begin
                case (pool_q)

                    // q=0: init max with first input
                    2'd0: begin
                        group0_window_valid <= 1'b1;
                        group0_window_id    <= pool_window_id;
                        group0_next_q       <= 2'd1;

                        group0_keep_reg <= i_keep;

                        group0_max0 <= input_lane0;
                        group0_max1 <= input_lane1;
                        group0_max2 <= input_lane2;
                    end

                    2'd1: begin
                        if (group0_keep_reg[0] && (input_lane0 > group0_max0))
                            group0_max0 <= input_lane0;

                        if (group0_keep_reg[1] && (input_lane1 > group0_max1))
                            group0_max1 <= input_lane1;

                        if (group0_keep_reg[2] && (input_lane2 > group0_max2))
                            group0_max2 <= input_lane2;

                        group0_next_q <= 2'd2;
                    end

                    2'd2: begin
                        if (group0_keep_reg[0] && (input_lane0 > group0_max0))
                            group0_max0 <= input_lane0;

                        if (group0_keep_reg[1] && (input_lane1 > group0_max1))
                            group0_max1 <= input_lane1;

                        if (group0_keep_reg[2] && (input_lane2 > group0_max2))
                            group0_max2 <= input_lane2;

                        group0_next_q <= 2'd3;
                    end

                    // q=3: final max goes straight to the output register
                    2'd3: begin
                        group0_window_valid <= 1'b0;
                        group0_next_q       <= 2'd0;
                    end

                    default: begin
                    end
                endcase
            end

            // group 1
            else begin
                case (pool_q)

                    2'd0: begin
                        group1_window_valid <= 1'b1;
                        group1_window_id    <= pool_window_id;
                        group1_next_q       <= 2'd1;

                        group1_keep_reg <= i_keep;

                        group1_max0 <= input_lane0;
                        group1_max1 <= input_lane1;
                        group1_max2 <= input_lane2;
                    end

                    2'd1: begin
                        if (group1_keep_reg[0] && (input_lane0 > group1_max0))
                            group1_max0 <= input_lane0;

                        if (group1_keep_reg[1] && (input_lane1 > group1_max1))
                            group1_max1 <= input_lane1;

                        if (group1_keep_reg[2] && (input_lane2 > group1_max2))
                            group1_max2 <= input_lane2;

                        group1_next_q <= 2'd2;
                    end

                    2'd2: begin
                        if (group1_keep_reg[0] && (input_lane0 > group1_max0))
                            group1_max0 <= input_lane0;

                        if (group1_keep_reg[1] && (input_lane1 > group1_max1))
                            group1_max1 <= input_lane1;

                        if (group1_keep_reg[2] && (input_lane2 > group1_max2))
                            group1_max2 <= input_lane2;

                        group1_next_q <= 2'd3;
                    end

                    2'd3: begin
                        group1_window_valid <= 1'b0;
                        group1_next_q       <= 2'd0;
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

endmodule

module result_buf (
    input  logic        clk,
    input  logic        rst_n,

    // ---- layer config ----
    input  logic        i_cfg_valid,
    input  logic        i_is_final_layer,
    input  logic [13:0] i_dst_base,
    input  logic [ 5:0] i_dst_channels,

    // ---- pooling_unit ----
    input  logic [23:0] i_data,
    input  logic        i_valid,
    output logic        o_ready,
    input  logic [ 2:0] i_keep,
    input  logic [18:0] i_meta,
    input  logic        i_write_grant,
    output logic        o_wr_en,
    output logic [13:0] o_wr_addr,
    output logic [23:0] o_wr_data,
    output logic [ 2:0] o_wr_be,

    // ---- post_process scalar ----
    input logic signed [7:0] i_final_data,
    input  logic        i_final_valid,
    output logic        o_final_ready,
    output logic        o_final_tile_done,

    // ---- Done / CSR ----
    output logic               o_layer_done,
    input  logic               i_irq_en,
    input  logic               i_irq_clear,
    output logic signed [31:0] o_final_result,
    output logic               o_done_status,
    output logic               o_irq
);

    // ---- cfg ----
    logic        is_final;
    logic [13:0] dst_base;
    logic [ 3:0] wpp;                         // words per pixel = ceil(C/3), 1..11
    logic        final_stored;
    logic        layer_done_sent;             // blocks duplicate layer_done

    function automatic logic [3:0] ceil_div3(input logic [5:0] c);
        begin ceil_div3 = ({2'b00, c} + 8'd2) / 8'd3; end
    endfunction

    // ---- intermediate layer write ----
    logic [11:0] m_pos;
    assign m_pos  = i_meta[11:0];
    logic [ 4:0] m_ocb;
    assign m_ocb  = i_meta[16:12];
    logic        m_lend;
    assign m_lend = i_meta[18];

    logic [15:0] pix_off;
    assign pix_off = m_pos * {12'd0, wpp};
    logic [ 3:0] ch_off;
    assign ch_off  = m_ocb / 5'd3;                         // channel group 0..10

    assign o_ready = rst_n && !i_cfg_valid && !is_final && !layer_done_sent && i_write_grant;         // no queue: write when granted
    assign o_wr_en   = i_valid && o_ready;
    assign o_wr_addr = dst_base + pix_off[13:0] + {10'd0, ch_off};
    assign o_wr_data = i_data;
    assign o_wr_be   = i_keep;

    logic wr_fire;
    assign wr_fire     = o_wr_en;
    logic lend_fire;
    assign lend_fire   = wr_fire && m_lend && !layer_done_sent;

    assign o_final_ready = rst_n && !i_cfg_valid && is_final && !final_stored;
    logic  final_fire;
    assign final_fire    = i_final_valid && o_final_ready;

    assign o_irq = i_irq_en && o_done_status;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_final          <= 1'b0;
            dst_base          <= 14'd0;
            wpp               <= 4'd1;
            final_stored      <= 1'b0;
            layer_done_sent   <= 1'b0;
            o_final_tile_done <= 1'b0;
            o_layer_done      <= 1'b0;
            o_final_result    <= 32'd0;
            o_done_status     <= 1'b0;
        end else begin
            o_final_tile_done <= 1'b0;
            o_layer_done      <= 1'b0;

            if (i_cfg_valid) begin
                is_final        <= i_is_final_layer;
                dst_base        <= i_dst_base;
                wpp             <= ceil_div3(i_dst_channels);
                final_stored    <= 1'b0;
                layer_done_sent <= 1'b0;
            end

            if (lend_fire) begin
                o_layer_done    <= 1'b1;
                layer_done_sent <= 1'b1;
            end

            // final layer: store sign-extended angle
            if (final_fire) begin
                o_final_result    <= {{24{i_final_data[7]}}, i_final_data};
                final_stored      <= 1'b1;
                layer_done_sent   <= 1'b1;
                o_final_tile_done <= 1'b1;
                o_layer_done      <= 1'b1;
                o_done_status     <= 1'b1;
            end else if (i_irq_clear) begin
                o_done_status     <= 1'b0;
            end
        end
    end

endmodule
