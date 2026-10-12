`timescale 1ns / 1ps

module out_path (
    input wire clk,
    input wire rst_n,

    input wire               i_layer_cfg_valid,
    input wire               i_is_fc,
    input wire               i_is_final_layer,
    input wire               i_pool_en,
    input wire        [ 6:0] i_conv_w,
    input wire        [ 6:0] i_conv_h,
    input wire        [ 5:0] i_out_channels,
    input wire        [13:0] i_dst_base,
    input wire               i_relu_en,
    input wire signed [31:0] i_quant_multiplier,
    input wire        [ 5:0] i_quant_shift,
    input wire        [ 5:0] i_bias_base,

    // Final FC2 angle requantization
    input wire signed [31:0] i_angle_multiplier,
    input wire        [ 5:0] i_angle_shift,

    input wire        i_tile_cfg_valid,
    input wire [11:0] i_patch_base,
    input wire [ 4:0] i_out_ch_base,
    input wire [ 2:0] i_row_mask,
    input wire [ 2:0] i_col_mask,
    input wire        i_tile_last,

    input wire [287:0] i_result_data,
    input wire [  8:0] i_result_valid,

    output wire o_result_space_ready,

    input wire i_param_load_start,

    input wire               i_param_wr_en,
    input wire        [ 5:0] i_param_wr_addr,
    input wire signed [31:0] i_param_wr_data,

    output wire o_param_load_done,

    output wire o_params_ready,

    input wire i_write_grant,

    output wire        o_wr_en,
    output wire [13:0] o_wr_addr,
    output wire [23:0] o_wr_data,
    output wire [ 2:0] o_wr_be,

    input wire i_irq_en,
    input wire i_irq_clear,

    output wire o_tile_in_done,
    output wire o_layer_done,

    output wire signed [31:0] o_final_result,
    output wire               o_done_status,
    output wire               o_irq
);
    // =========================================================
    // Layer Configuration Registers
    // =========================================================
    reg               is_fc_reg;
    reg               is_final_layer_reg;
    reg               pool_en_reg;
    reg        [ 6:0] conv_w_reg;
    reg        [ 5:0] out_channels_reg;
    reg        [13:0] dst_base_reg;
    reg               relu_en_reg;
    reg signed [31:0] quant_multiplier_reg;
    reg        [ 5:0] quant_shift_reg;
    reg        [ 5:0] bias_base_reg;

    reg signed [31:0] angle_multiplier_reg;
    reg        [ 5:0] angle_shift_reg;

    always @(posedge clk or negedge rst_n) begin
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

    // =========================================================
    // Tile configuration passthrough
    // =========================================================
    wire        fifo_cfg_ready;
    wire        pp_cfg_ready;
    wire        tile_cfg_fire = i_tile_cfg_valid;

    // =========================================================
    // Output FIFO Interface Wires
    // =========================================================

    wire        [95:0] fifo_data;
    wire               fifo_valid;
    wire        [ 2:0] fifo_keep;
    wire        [18:0] fifo_meta;
    wire               fifo_ready;

    // =========================================================
    // Post Process Interface Wires
    // =========================================================
    wire               pp_params_ready;

    wire               pp_bias_req_valid;
    wire               pp_bias_req_ready;
    wire        [ 5:0] pp_bias_addr;

    wire signed [31:0] pp_bias_data;
    wire               pp_bias_rsp_valid;
    wire               pp_bias_rsp_ready;

    wire        [23:0] pp_data;
    wire               pp_valid;
    wire        [ 2:0] pp_keep;
    wire        [18:0] pp_meta;
    wire               pp_ready;

    wire signed [ 7:0] pp_final_data;
    wire               pp_final_valid;
    wire               pp_final_ready;

    wire               params_loaded;

    assign o_params_ready = pp_params_ready;

    // =========================================================
    // Pooling Unit Interface Wires
    // =========================================================
    wire        [23:0] pool_data;
    wire               pool_valid;
    wire        [ 2:0] pool_keep;
    wire        [18:0] pool_meta;
    wire               pool_ready;

    wire               pool_tile_in_done;
    wire               result_final_tile_done;

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
    input wire clk,
    input wire rst_n,

    // Tile configuration
    input wire        i_cfg_valid,
    input wire [11:0] i_patch_base,
    input wire [ 4:0] i_out_ch_base,
    input wire [ 2:0] i_row_mask,
    input wire [ 2:0] i_col_mask,
    input wire        i_tile_last,

    input wire       i_is_fc,
    input wire [6:0] i_conv_w,

    // PE result input
    input wire [287:0] i_result_data,
    input wire [  8:0] i_result_valid,

    // Tile configuration handshake
    output wire o_cfg_ready,

    // PE result space status
    output wire o_result_space_ready,

    // Output
    output reg  [95:0] o_data,
    output reg         o_valid,
    input  wire        i_ready,

    output reg  [ 2:0] o_keep,
    output wire [18:0] o_meta
);

    // result save register
    reg  [95:0] row0_data;
    reg  [95:0] row1_data;
    reg  [95:0] row2_data;

    reg  [ 2:0] row0_valid;
    reg  [ 2:0] row1_valid;
    reg  [ 2:0] row2_valid;

    // tile set register
    reg  [11:0] patch_base_reg;
    reg  [ 4:0] out_ch_base_reg;
    reg  [ 2:0] row_mask_reg;
    reg  [ 2:0] col_mask_reg;
    reg         tile_last_reg;
    reg         is_fc_reg;
    reg  [ 6:0] conv_w_reg;
    reg  [ 2:0] conv_w_sh_reg;   // log2(conv_w)

    // Width shift helper
    function [2:0] f_log2_7;
        input [6:0] v;
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

    // output state register
    reg         tile_active;

    // output row num
    reg  [ 1:0] out_row;

    // handshake
    wire        cfg_fire;
    wire        out_fire;

    assign o_cfg_ready          = rst_n && !tile_active;
    assign o_result_space_ready = rst_n && !tile_active;

    wire cfg_mask_valid;

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

    // select first effective row
    reg [1:0] first_row;

    always @(*) begin
        first_row = 2'd3;

        if (i_row_mask[0]) begin
            first_row = 2'd0;
        end else if (i_row_mask[1]) begin
            first_row = 2'd1;
        end else if (i_row_mask[2]) begin
            first_row = 2'd2;
        end
    end

    // select next effective row
    reg [1:0] next_row;

    always @(*) begin
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

    wire row0_complete;
    wire row1_complete;
    wire row2_complete;

    assign row0_complete = row_mask_reg[0] && ((row0_valid & col_mask_reg) == col_mask_reg);
    assign row1_complete = row_mask_reg[1] && ((row1_valid & col_mask_reg) == col_mask_reg);
    assign row2_complete = row_mask_reg[2] && ((row2_valid & col_mask_reg) == col_mask_reg);

    wire last_valid_row;

    wire last_valid_0 = (out_row == 2'd0) && row_mask_reg[0] && !row_mask_reg[1] && !row_mask_reg[2];
    wire last_valid_1 = (out_row == 2'd1) && row_mask_reg[1] && !row_mask_reg[2];
    wire last_valid_2 = (out_row == 2'd2) && row_mask_reg[2];

    assign last_valid_row = last_valid_0 || last_valid_1 || last_valid_2;

    // select out_row data
    reg [95:0] selected_row_data;
    reg        selected_row_complete;

    always @(*) begin
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


    // output
    always @(*) begin
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

    wire [11:0] current_position;

    // 2x2 Z-order patch mapping
    wire [11:0] cur_patch = patch_base_reg + {10'd0, out_row};
    wire [ 9:0] blk       = cur_patch[11:2];                                   // 2x2 block index
    wire [ 1:0] q         = cur_patch[1:0];                                    // Position within 2x2 block
    wire [ 2:0] wpr_sh    = (conv_w_sh_reg == 3'd0) ? 3'd0 : (conv_w_sh_reg - 3'd1);   // log2(W/2)
    wire [ 9:0] by        = blk >> wpr_sh;
    wire [ 9:0] bx        = blk & ((10'd1 << wpr_sh) - 10'd1);
    wire [11:0] pos_y     = {1'b0, by, 1'b0} + {11'd0, q[1]};
    wire [11:0] pos_x     = {1'b0, bx, 1'b0} + {11'd0, q[0]};

    assign current_position = is_fc_reg ? 12'd0 : ((pos_y << conv_w_sh_reg) | pos_x);
    assign o_meta = {
        tile_last_reg && last_valid_row,  // [18] layer_end
        last_valid_row,  // [17] tile_end
        out_ch_base_reg,  // [16:12] out_ch_base
        current_position  // [11:0] position
    };

    always @(posedge clk or negedge rst_n) begin
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
    parameter integer PARAM_TOTAL = 43      // 43 : Conv0 6 + Conv1 4 + fc1 32 + fc2 1
) (
    input  wire        clk,
    input  wire        rst_n,

    // cnn_cntl -> out_path
    input  wire               i_load_start,
    input  wire               i_wr_en,
    input  wire        [ 5:0] i_wr_addr,
    input  wire signed [31:0] i_wr_data,
    output reg                o_load_done,
    output reg                o_loaded,

    // -> post_process
    input  wire               i_rd_req_valid,
    output wire               o_rd_req_ready,
    input  wire        [ 5:0] i_rd_addr,
    output reg  signed [31:0] o_rd_data,
    output reg                o_rd_rsp_valid,
    input  wire               i_rd_rsp_ready      
);

    reg signed [31:0] mem [0:63];                // 64-depth. Using only 0 ~ 42
    reg        loading;                     // i_load_start ~ last store = High-state
    reg [ 5:0] wr_cnt;                      // Load counter 0 ~ 43

    wire wr_fire = loading && !i_load_start && i_wr_en;
    wire wr_last   = wr_fire && (wr_cnt == PARAM_TOTAL - 1); // 43th store
    wire req_fire  = i_rd_req_valid && o_rd_req_ready;
    wire rsp_fire  = o_rd_rsp_valid && i_rd_rsp_ready;

    // Read request Access state condition
    // Back-to-back read requests
    assign o_rd_req_ready = o_loaded && !loading && !i_load_start && (!o_rd_rsp_valid || i_rd_rsp_ready);

    // memory Read/Write
    always @(posedge clk) begin
        if (wr_fire)  mem[i_wr_addr] <= i_wr_data;
        if (req_fire) o_rd_data      <= mem[i_rd_addr];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loading        <= 1'b0;
            wr_cnt         <= 6'd0;
            o_load_done    <= 1'b0;
            o_loaded       <= 1'b0;
            o_rd_rsp_valid <= 1'b0;
        end else begin
            o_load_done <= 1'b0;                 

            if (i_load_start) begin // Load Start
                loading        <= 1'b1;
                wr_cnt         <= 6'd0;
                o_loaded       <= 1'b0;
                o_rd_rsp_valid <= 1'b0;
            end else if (wr_fire) begin
                wr_cnt <= wr_cnt + 6'd1;
                if (wr_last) begin // Last Parameter Store
                    loading     <= 1'b0;
                    o_loaded    <= 1'b1;
                    o_load_done <= 1'b1;
                end
            end

            // Read response
            if      (req_fire)      o_rd_rsp_valid <= 1'b1;
            else if (rsp_fire)      o_rd_rsp_valid <= 1'b0;
        end
    end

endmodule

module post_process (
    input wire clk,
    input wire rst_n,

    // Tile / Layer Configuration
    input wire i_cfg_valid,
    output wire o_cfg_ready,

    input wire [2:0] i_col_mask,
    input wire [4:0] i_out_ch_base,

    input wire [5:0] i_bias_base,
    input wire       i_relu_en,
    input wire       i_is_final_layer,

    input wire signed [31:0] i_quant_multiplier,
    input wire        [ 5:0] i_quant_shift,

    input wire signed [31:0] i_angle_multiplier,
    input wire        [ 5:0] i_angle_shift,

    // Parameter Buffer Interface
    input  wire i_params_loaded,
    output reg  o_params_ready,

    // Bias Read Request
    output reg        o_bias_req_valid,
    input  wire       i_bias_req_ready,
    output reg  [5:0] o_bias_addr,

    // Bias Read Response
    input  wire signed [31:0] i_bias_data,
    input  wire               i_bias_rsp_valid,
    output reg                o_bias_rsp_ready,

    // Input Stream from Output FIFO
    input  wire [95:0] i_data,
    input  wire        i_valid,
    output reg         o_ready,

    input wire [ 2:0] i_keep,
    input wire [18:0] i_meta,

    // Normal Output Stream to Pooling Unit
    // 3 lanes x INT8 = 24-bit
    output reg  [23:0] o_data,
    output reg         o_valid,
    input  wire        i_ready,

    output reg [ 2:0] o_keep,
    output reg [18:0] o_meta,

    // Final Layer Output to Result Buffer
    // INT32 scalar path
    output reg signed [7:0] o_final_data,
    output reg              o_final_valid,
    input  wire             i_final_ready
);
    // =========================================================
    // Internal Configuration Registers
    // =========================================================

    // Valid output lanes
    // 001 : lane0
    // 011 : lane0~1
    // 111 : lane0~2
    reg [2:0] col_mask_reg;

    // First output channel
    reg [4:0] out_ch_base_reg;

    // Bias base address
    reg [5:0] bias_base_reg;

    // ReLU enable
    reg relu_en_reg;

    // Final-layer selection
    reg is_final_layer_reg;

    // Requant multiplier
    reg signed [31:0] quant_multiplier_reg;

    // Requant shift
    reg        [ 5:0] quant_shift_reg;

    // Final angle multiplier
    reg signed [31:0] angle_multiplier_reg;

    // Final angle shift
    reg        [ 5:0] angle_shift_reg;

    // Tile configuration enable
    reg cfg_change_allowed;


    // =========================================================
    // Bias Cache
    // =========================================================

    // Bias cache per output channel
    reg signed [31:0] bias_cache0;
    reg signed [31:0] bias_cache1;
    reg signed [31:0] bias_cache2;

    // Sequential bias requests
    reg [1:0] bias_req_idx;      // Next requested lane
    reg [1:0] bias_rsp_idx;      // Next response lane
    reg [1:0] bias_n_lanes;      // Active lane count

    // Two-entry bias cache
    reg        [ 1:0] bc_valid;
    reg        [13:0] bc_key0, bc_key1;           // {bias_base[5:0], out_ch_base[4:0], col_mask[2:0]}
    reg signed [31:0] bc0_b0, bc0_b1, bc0_b2;
    reg signed [31:0] bc1_b0, bc1_b1, bc1_b2;
    reg               bc_next;                    // Next cache entry
    wire       [13:0] cfg_key  = {i_bias_base, i_out_ch_base, i_col_mask};
    wire              cfg_hit0 = bc_valid[0] && (bc_key0 == cfg_key);
    wire              cfg_hit1 = bc_valid[1] && (bc_key1 == cfg_key);
    wire              cfg_hit  = cfg_hit0 || cfg_hit1;


    // =========================================================
    // Input Beat Buffer
    // =========================================================

    // 96-bit input beat
    reg [95:0] data_reg;

    // Valid lane mask
    reg [2:0] keep_reg;

    // Input metadata
    reg [18:0] meta_reg;


    // =========================================================
    // Input Lane Split
    // =========================================================

    // Three signed INT32 lanes
    wire signed [31:0] lane0_data;
    wire signed [31:0] lane1_data;
    wire signed [31:0] lane2_data;

    assign lane0_data = $signed(data_reg[31:0]);
    assign lane1_data = $signed(data_reg[63:32]);
    assign lane2_data = $signed(data_reg[95:64]);


    // =========================================================
    // Lane Processing Control
    // =========================================================

    // Current lane index
    reg [1:0] lane_idx;

    // Selected PE result
    reg signed [31:0] current_lane_data;

    // Selected bias
    reg signed [31:0] current_bias;

    // Selected lane validity
    reg current_lane_valid;

    // =========================================================
    // Current Lane Selector
    // =========================================================
    always @(*) begin
        // Default values
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

    // =========================================================
    // Four-stage requant pipeline
    // =========================================================

    // S0: Bias addition and INT32 saturation
    reg signed [32:0] bias_sum_ext;   // Extended sum for overflow
    reg signed [31:0] acc32_reg;      // Saturated INT32 accumulator

    always @(*) begin
        bias_sum_ext = {current_lane_data[31], current_lane_data} + {current_bias[31], current_bias};
    end

    always @(*) begin
        case (bias_sum_ext[32:31])
            2'b01:   acc32_reg = 32'h7FFF_FFFF;   // Positive overflow
            2'b10:   acc32_reg = 32'h8000_0000;   // Negative overflow
            default: acc32_reg = bias_sum_ext[31:0];
        endcase
    end

    // Select layer multiplier and shift
    reg signed [31:0] current_multiplier;
    reg        [ 5:0] current_shift;

    always @(*) begin
        if (is_final_layer_reg) begin
            current_multiplier = angle_multiplier_reg;
            current_shift      = angle_shift_reg;
        end
        else begin
            current_multiplier = quant_multiplier_reg;
            current_shift      = quant_shift_reg;
        end
    end

    // Pipeline registers
    reg               s1_valid, s2_valid, s3_valid;   // Stage valid bits
    reg        [ 1:0] s1_lane,  s2_lane,  s3_lane;    // Stage lane indices
    reg               s1_last,  s2_last,  s3_last;    // Last-lane flags
    reg signed [31:0] s1_acc32;
    reg signed [31:0] s1_mult;
    reg signed [63:0] s2_prod;
    reg signed [63:0] s3_sum;

    // Round to nearest, ties away from zero
    //   P >= 0 : (P + 2^(S-1)) >> S
    wire        [63:0] round_half = (current_shift == 6'd0) ? 64'd0 : (64'd1 << (current_shift - 6'd1));
    wire signed [63:0] round_off  = (current_shift == 6'd0) ? 64'sd0 :
                                    (s2_prod[63] ? ($signed(round_half) - 64'sd1) : $signed(round_half));

    // Signed right shift
    wire signed [63:0] rounded_result = s3_sum >>> current_shift;

    // ReLU and INT8 saturation
    reg signed [7:0] normal_int8_result;

    always @(*) begin
        if (relu_en_reg && rounded_result[63])        normal_int8_result = 8'd0;    // ReLU
        else if (rounded_result > $signed(64'd127))   normal_int8_result = 8'h7F;   // Upper saturation
        else if (rounded_result < -$signed(64'd128))  normal_int8_result = 8'h80;   // Lower saturation
        else                                          normal_int8_result = rounded_result[7:0];
    end

    // Final INT8 output without ReLU
    reg signed [7:0] final_int8_result;

    always @(*) begin
        if (rounded_result > $signed(64'd127))        final_int8_result = 8'h7F;
        else if (rounded_result < -$signed(64'd128))  final_int8_result = 8'h80;
        else                                          final_int8_result = rounded_result[7:0];
    end

    // Hold final result until accepted
    reg signed [7:0] final_result_reg;

    // =========================================================
    // Normal INT8 Output Lane Registers
    // =========================================================

    // Processed INT8 lanes
    reg signed [7:0] result_lane0;
    reg signed [7:0] result_lane1;
    reg signed [7:0] result_lane2;

    // Last lane issued
    reg issue_done;

    // =========================================================
    // FSM State
    // =========================================================
    reg [2:0] state;
    reg [2:0] next_state;

    // FSM state
    localparam IDLE       = 3'd0; // Wait for tile config
    localparam BIAS_REQ   = 3'd1; // Request bias data
    localparam BIAS_WAIT  = 3'd2; // Wait for bias response
    localparam READY      = 3'd3; // Wait for input beat
    localparam PROCESS    = 3'd4; // Process lanes
    localparam OUT_WAIT   = 3'd5; // Wait for normal output
    localparam FINAL_WAIT = 3'd6; // Wait for final output

    // =========================================================
    // Handshake Wires
    // =========================================================

    // Input handshake
    wire input_fire;

    // Normal output handshake
    wire output_fire;

    // Final output handshake
    wire final_fire;

    // Bias request handshake
    wire bias_req_fire;

    // Bias response handshake
    wire bias_rsp_fire;

    // Tile configuration handshake
    wire cfg_fire;

    // Validate channel mask
    // Normal Layer : 001 / 011 / 111
    wire cfg_mask_valid;

    assign cfg_mask_valid = i_is_final_layer ? (i_col_mask == 3'b001) : 
            ((i_col_mask == 3'b001) ||
             (i_col_mask == 3'b011) ||
             (i_col_mask == 3'b111));

    // Last bias address
    wire [6:0] cfg_bias_last_addr;

    // Validate bias address
    wire cfg_bias_addr_valid;

    // Validate final FC2 config
    wire cfg_final_valid;

    assign cfg_final_valid = !i_is_final_layer || (
            (i_out_ch_base == 5'd0) &&
            (i_bias_base   == 6'd42) &&
            (i_relu_en     == 1'b0));

    assign cfg_bias_last_addr = {1'b0, i_bias_base} + {2'b00, i_out_ch_base} + 
        ((i_col_mask == 3'b111) ? 7'd2 : (i_col_mask == 3'b011) ? 7'd1 : 7'd0);

    assign cfg_bias_addr_valid = (cfg_bias_last_addr <= 7'd42);

    // Validate input lane mask
    wire input_keep_valid;

    // Validate final FC2 input
    wire final_input_valid;

    // Validate input metadata
    wire input_meta_valid;

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

    // Last bias response
    wire bias_rsp_last = bias_rsp_fire && (bias_rsp_idx == bias_n_lanes - 2'd1);

    // =========================================================
    // Lane issue and completion
    // =========================================================

    // Last valid lane
    wire [1:0] last_lane_idx = keep_reg[2] ? 2'd2 : (keep_reg[1] ? 2'd1 : 2'd0);

    // Issue last lane
    wire       issue_last    = (state == PROCESS) && !issue_done && (lane_idx == last_lane_idx);

    // Last lane completed
    wire       process_done  = (state == PROCESS) && s3_last;

    // =========================================================
    // FSM State Register
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // =========================================================
    // FSM Next State Logic
    // =========================================================
    always @(*) begin
        next_state = state;

        case (state)
            // -------------------------------------------------
            // Wait for tile configuration
            // -------------------------------------------------
            IDLE: begin
                if (cfg_fire)
                    next_state = cfg_hit ? READY : BIAS_REQ;   // Bias cache hit
            end


            // -------------------------------------------------
            // Request lane biases
            // -------------------------------------------------
            BIAS_REQ: begin
                // Request all required biases
                if (bias_rsp_last)
                    next_state = READY;
            end


            // -------------------------------------------------
            // Legacy bias wait state
            // -------------------------------------------------
            BIAS_WAIT: begin
                // Unused state
                next_state = READY;
            end


            // -------------------------------------------------
            // Wait for FIFO data
            // -------------------------------------------------
            READY: begin
                if (cfg_fire) begin
                    next_state = cfg_hit ? READY : BIAS_REQ;
                end
                else if (input_fire) begin
                    next_state = PROCESS;
                end
            end


            // -------------------------------------------------
            // Process input lanes
            // -------------------------------------------------
            PROCESS: begin
                if (process_done) begin
                    if (is_final_layer_reg)
                        next_state = FINAL_WAIT;
                    else
                        next_state = OUT_WAIT;
                end
            end


            // -------------------------------------------------
            // Wait for pooling handshake
            // -------------------------------------------------
            OUT_WAIT: begin
                if (output_fire)
                    next_state = READY;
            end


            // -------------------------------------------------
            // Wait for final result handshake
            // -------------------------------------------------
            FINAL_WAIT: begin
                if (final_fire)
                    next_state = READY;
            end


            default: begin
                next_state = IDLE;
            end

        endcase
    end


    // =========================================================
    // FSM Output / Control Logic
    // =========================================================
    always @(*) begin
        // -----------------------------------------------------
        // Default outputs
        // -----------------------------------------------------
        o_params_ready   = 1'b0;

        o_bias_req_valid = 1'b0;
        o_bias_addr      = 6'd0;
        o_bias_rsp_ready = 1'b0;

        o_ready          = 1'b0;

        // Drive registered data directly
        o_data           = {result_lane2, result_lane1, result_lane0};
        o_valid          = 1'b0;
        o_keep           = keep_reg;
        o_meta           = meta_reg;
        o_final_data     = final_result_reg;
        o_final_valid    = 1'b0;


        case (state)

            IDLE: begin
                // Wait for configuration
            end

            BIAS_REQ: begin
                // Issue pending bias requests
                o_bias_req_valid = (bias_req_idx < bias_n_lanes);
                o_bias_addr      = bias_base_reg + out_ch_base_reg + bias_req_idx;
                o_bias_rsp_ready = 1'b1;
            end

            BIAS_WAIT: begin
            end

            READY: begin
                // Bias cache ready
                o_params_ready = 1'b1;
                // Block input during config
                // Validate incoming beat
                o_ready = !cfg_change_allowed && !cfg_fire && (!i_valid || (input_keep_valid && input_meta_valid && final_input_valid));
            end

            PROCESS: begin
                // Bias cache ready
                o_params_ready = 1'b1;

                // Block input during processing
            end

            OUT_WAIT: begin
                // Bias cache ready
                o_params_ready = 1'b1;
                // Pack three INT8 lanes
                o_data  = {result_lane2, result_lane1, result_lane0};
                // Forward valid lane mask
                o_keep  = keep_reg;
                // Forward metadata
                o_meta  = meta_reg;
                // Assert output valid
                o_valid = 1'b1;
            end

            FINAL_WAIT: begin
                // Bias cache ready
                o_params_ready = 1'b1;

                // Signed INT8 angle result
                o_final_data  = final_result_reg;
                o_final_valid = 1'b1;
            end

            default: begin
            end

        endcase
    end

    // =========================================================
    // Configuration Register Update
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
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

    // =========================================================
    // Tile Configuration Lock
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Allow initial configuration
            cfg_change_allowed <= 1'b1;
        end
        else if (cfg_fire) begin
            // Lock configuration during tile
            cfg_change_allowed <= 1'b0;
        end
        else if (output_fire && meta_reg[17]) begin
            // Unlock after final output row
            cfg_change_allowed <= 1'b1;
        end
        else if (final_fire) begin
            // Unlock after final result
            cfg_change_allowed <= 1'b1;
        end
    end

    // =========================================================
    // Bias read and cache update
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
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
            // Invalidate cache on parameter reload
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
                // Store received biases in cache
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


    // =========================================================
    // Input Beat Buffer Update
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_reg <= 96'd0;
            keep_reg <= 3'b000;
            meta_reg <= 19'd0;
        end
        else if (input_fire) begin
            // Capture accepted input beat
            data_reg <= i_data;
            keep_reg <= i_keep;
            meta_reg <= i_meta;
        end
    end

    // =========================================================
    // Lane pipeline
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
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
            // Advance pipeline every cycle
            // S0 to S1: Capture lane
            s1_valid <= (state == PROCESS) && !issue_done && current_lane_valid;
            s1_lane  <= lane_idx;
            s1_last  <= issue_last;
            s1_acc32 <= acc32_reg;
            s1_mult  <= current_multiplier;

            // S1 to S2: Signed multiply
            s2_valid <= s1_valid;
            s2_lane  <= s1_lane;
            s2_last  <= s1_last;
            s2_prod  <= s1_acc32 * s1_mult;

            // S2 to S3: Add rounding offset
            s3_valid <= s2_valid;
            s3_lane  <= s2_lane;
            s3_last  <= s2_last;
            s3_sum   <= s2_prod + round_off;

            // S3: Shift and saturate
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
                    // Final FC2 uses lane 0
                    final_result_reg <= final_int8_result;
                end
            end

            // Issue next lane
            if (input_fire) begin
                // Clear previous lane results
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
    input wire clk,
    input wire rst_n,

    // =========================================================
    // Layer Configuration
    // =========================================================
    input wire       i_cfg_valid,
    input wire       i_pool_en,
    input wire [6:0] i_in_w,
    input wire [6:0] i_in_h,
    input wire [5:0] i_channels,

    // =========================================================
    // Input Stream from post_process
    // =========================================================
    input  wire [23:0] i_data,
    input  wire        i_valid,
    output wire        o_ready,

    input wire [ 2:0] i_keep,
    input wire [18:0] i_meta,

    // =========================================================
    // Output Stream to result_buf
    // =========================================================
    output wire [23:0] o_data,
    output wire        o_valid,
    input  wire        i_ready,

    output wire [ 2:0] o_keep,
    output wire [18:0] o_meta,

    // =========================================================
    // Tile Input Completion
    // =========================================================
    output reg o_tile_in_done
);

    // =========================================================
    // Layer Configuration Registers
    // =========================================================
    reg       pool_en_reg;
    reg [6:0] in_w_reg;
    reg [6:0] in_h_reg;
    reg [5:0] channels_reg;
    reg [2:0] in_w_sh_reg;     // log2(input width)
    reg [6:0] in_w_mask_reg;   // in_w - 1

    // Input width shift helper
    function [2:0] f_log2_7;
        input [6:0] v;
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

    always @(posedge clk or negedge rst_n) begin
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

    // =========================================================
    // Input Metadata Decode
    // =========================================================

    // i_meta[11:0]  : input spatial position
    // i_meta[16:12] : output channel base
    // i_meta[17]    : tile_end
    // i_meta[18]    : layer_end
    wire [11:0] input_pos;
    wire [ 4:0] input_out_ch_base;
    wire        input_tile_end;
    wire        input_layer_end;

    assign input_pos         = i_meta[11:0];
    assign input_out_ch_base = i_meta[16:12];
    assign input_tile_end    = i_meta[17];
    assign input_layer_end   = i_meta[18];

    // Channel group selection
    // Current MaxPool layer has 6 output channels.
    //
    // group 0 : channel 0 ~ 2, out_ch_base = 0
    // group 1 : channel 3 ~ 5, out_ch_base = 3
    wire pool_group_sel;

    assign pool_group_sel = (input_out_ch_base == 5'd3);

    // =========================================================
    // Position Decode
    // =========================================================

    // pos = y * in_w + x
    wire [11:0] input_y_full;
    wire [11:0] input_x_full;

    // Shift-based position calculation
    assign input_y_full = input_pos >> in_w_sh_reg;
    assign input_x_full = input_pos & {5'd0, in_w_mask_reg};

    wire [6:0] input_y;
    wire [6:0] input_x;

    assign input_y = input_y_full[6:0];
    assign input_x = input_x_full[6:0];

    // =========================================================
    // 2x2 Pool Window Position
    // =========================================================

    // q = 2 * (y % 2) + (x % 2)
    //
    // q=0 : top-left
    // q=1 : top-right
    // q=2 : bottom-left
    // q=3 : bottom-right
    wire [1:0] pool_q;

    assign pool_q = {input_y[0], input_x[0]};

    // Pool output position
    // pool_pos = (y/2) * (in_w/2) + (x/2)
    wire [11:0] pool_position;

    // (y/2) * (in_w/2) + (x/2)  =  (y/2) << (log2(in_w) - 1)  |  (x/2)
    wire [11:0] pool_y2 = {6'd0, input_y[6:1]};
    wire [11:0] pool_x2 = {6'd0, input_x[6:1]};
    assign pool_position = (in_w_sh_reg == 3'd0) ? 12'd0 : ((pool_y2 << (in_w_sh_reg - 3'd1)) | pool_x2);

    // 2x2 window ID
    wire [11:0] pool_window_id;

    assign pool_window_id = pool_position;

    // =========================================================
    // Input / Output Handshake
    // =========================================================

    // Pending pooled output
    reg  [23:0] out_data_reg;
    reg         out_valid_reg;
    reg  [ 2:0] out_keep_reg;
    reg  [18:0] out_meta_reg;

    wire        input_fire;
    wire        output_fire;
    wire        pool_state_ready;

    // Output slot availability
    assign o_ready =
        rst_n &&
        !i_cfg_valid &&
        (!out_valid_reg || i_ready) &&
        (!i_valid || pool_state_ready);

    assign input_fire = i_valid && o_ready;
    assign output_fire = out_valid_reg && i_ready;

    // Output stream
    assign o_data = out_data_reg;
    assign o_valid = out_valid_reg;
    assign o_keep = out_keep_reg;
    assign o_meta = out_meta_reg;

    // =========================================================
    // Input Lane Split
    // =========================================================

    wire signed [7:0] input_lane0;
    wire signed [7:0] input_lane1;
    wire signed [7:0] input_lane2;

    assign input_lane0 = $signed(i_data[7:0]);
    assign input_lane1 = $signed(i_data[15:8]);
    assign input_lane2 = $signed(i_data[23:16]);

    // =========================================================
    // Pool Channel Group Select
    // =========================================================



    // =========================================================
    // Group 0 Pool State : Channel 0 ~ 2
    // =========================================================

    // Active window flag
    reg               group0_window_valid;

    // Current window ID
    reg        [11:0] group0_window_id;

    // Expected next quadrant
    // 0 -> 1 -> 2 -> 3
    reg        [ 1:0] group0_next_q;

    // Running max per lane
    reg signed [ 7:0] group0_max0;
    reg signed [ 7:0] group0_max1;
    reg signed [ 7:0] group0_max2;
    reg [2:0] group0_keep_reg;

    // =========================================================
    // Group 1 Pool State : Channel 3 ~ 5
    // =========================================================

    reg               group1_window_valid;
    reg        [11:0] group1_window_id;
    reg        [ 1:0] group1_next_q;

    reg signed [ 7:0] group1_max0;
    reg signed [ 7:0] group1_max1;
    reg signed [ 7:0] group1_max2;
    reg [2:0] group1_keep_reg;

    // =========================================================
    // Final Max for q=3
    // =========================================================

    wire signed [7:0] group0_final_max0;
    wire signed [7:0] group0_final_max1;
    wire signed [7:0] group0_final_max2;

    wire signed [7:0] group1_final_max0;
    wire signed [7:0] group1_final_max1;
    wire signed [7:0] group1_final_max2;

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

    // =========================================================
    // Last Pool Output Detection
    // =========================================================

    wire [2:0] input_valid_lane_count;
    wire [6:0] input_group_end_ch;

    wire pool_last_window;
    wire pool_last_group;
    wire pool_output_layer_end;

    assign input_valid_lane_count =
        {2'd0, i_keep[0]} +
        {2'd0, i_keep[1]} +
        {2'd0, i_keep[2]};

    // exclusive end channel
    // ex) base=3, keep=111 -> 3+3=6
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

    // =========================================================
    // Input Validity Check
    // =========================================================
    wire input_keep_valid;
    wire input_position_valid;
    wire pool_group_valid;
    wire pool_cfg_valid;
    wire pool_layer_end_valid;
    // =========================================================
    // Pool Configuration Validity
    // =========================================================

    // 2x2 MaxPool configuration checks
    assign pool_cfg_valid =
        (in_w_reg >= 7'd2) &&
        (in_h_reg >= 7'd2) &&
        (in_w_reg[0] == 1'b0) &&
        (in_h_reg[0] == 1'b0) &&
        ((in_w_reg & (in_w_reg - 7'd1)) == 7'd0) &&   // Require power-of-two width
        (channels_reg >= 6'd1) &&
        (channels_reg <= 6'd6);

    // Validate final pooling window
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

    // Valid channel group bases
    assign pool_group_valid =
        (input_out_ch_base == 5'd0) ||
        (input_out_ch_base == 5'd3);

    // =========================================================
    // Pool Input Sequence Check
    // =========================================================

    // Bypass input ready
    //
    // Enforce quadrant order
    //
    // Start new window at q0
    // Match window ID and quadrant
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
        
    // Output processing after declarations
    // =========================================================
    // Output Register / Tile Input Done
    // =========================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_data_reg      <= 24'd0;
            out_valid_reg     <= 1'b0;
            out_keep_reg      <= 3'b000;
            out_meta_reg      <= 19'd0;

            o_tile_in_done    <= 1'b0;
        end
        else begin
            // Default completion pulse
            o_tile_in_done <= 1'b0;

            // Clear pending output on layer change
            if (i_cfg_valid) begin
                out_valid_reg <= 1'b0;
            end
            else begin

                // Release accepted output
                if (output_fire) begin
                    out_valid_reg <= 1'b0;
                end

                // -------------------------------------------------
                // Capture accepted input
                // -------------------------------------------------
                if (input_fire) begin

                    // =============================================
                    // Bypass
                    // =============================================
                    if (!pool_en_reg) begin
                        out_data_reg  <= i_data;
                        out_keep_reg  <= i_keep;
                        out_meta_reg  <= i_meta;
                        out_valid_reg <= 1'b1;
                    end

                    // =============================================
                    // 2x2 MaxPool
                    // Emit output at q3
                    // =============================================
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

                        // Pool output metadata
                        //
                        // [18] layer_end
                        // Tile end disabled
                        // [16:12] out_ch_base
                        // [11:0] pooled position
                        out_meta_reg <= {
                            pool_output_layer_end,
                            1'b0,
                            input_out_ch_base,
                            pool_position
                        };

                        out_valid_reg <= 1'b1;
                    end

                    // Last input beat accepted
                    if (input_tile_end) begin
                        o_tile_in_done <= 1'b1;
                    end
                end
            end
        end
    end
    

    // =========================================================
    // Pool State Update
    // =========================================================

    always @(posedge clk or negedge rst_n) begin
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
            // Clear pool state on new layer
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

            // =================================================
            // Group 0 : Channel 0 ~ 2
            // =================================================
            if (!pool_group_sel) begin
                case (pool_q)

                    // Initialize max at q0
                    2'd0: begin
                        group0_window_valid <= 1'b1;
                        group0_window_id    <= pool_window_id;
                        group0_next_q       <= 2'd1;

                        group0_keep_reg <= i_keep;

                        group0_max0 <= input_lane0;
                        group0_max1 <= input_lane1;
                        group0_max2 <= input_lane2;
                    end

                    // q=1
                    2'd1: begin
                        if (group0_keep_reg[0] && (input_lane0 > group0_max0))
                            group0_max0 <= input_lane0;

                        if (group0_keep_reg[1] && (input_lane1 > group0_max1))
                            group0_max1 <= input_lane1;

                        if (group0_keep_reg[2] && (input_lane2 > group0_max2))
                            group0_max2 <= input_lane2;

                        group0_next_q <= 2'd2;
                    end

                    // q=2
                    2'd2: begin
                        if (group0_keep_reg[0] && (input_lane0 > group0_max0))
                            group0_max0 <= input_lane0;

                        if (group0_keep_reg[1] && (input_lane1 > group0_max1))
                            group0_max1 <= input_lane1;

                        if (group0_keep_reg[2] && (input_lane2 > group0_max2))
                            group0_max2 <= input_lane2;

                        group0_next_q <= 2'd3;
                    end

                    // q=3 :
                    // Write final max to output
                    2'd3: begin
                        group0_window_valid <= 1'b0;
                        group0_next_q       <= 2'd0;
                    end

                    default: begin
                    end
                endcase
            end

            // =================================================
            // Group 1 : Channel 3 ~ 5
            // =================================================
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
    input  wire        clk,
    input  wire        rst_n,

    // ---- layer config ----
    input  wire        i_cfg_valid,         
    input  wire        i_is_final_layer,    
    input  wire [13:0] i_dst_base,          
    input  wire [ 5:0] i_dst_channels,      

    // ---- pooling_unit ----
    input  wire [23:0] i_data,            
    input  wire        i_valid,           
    output wire        o_ready,           
    input  wire [ 2:0] i_keep,            
    input  wire [18:0] i_meta,            
    input  wire        i_write_grant,     
    output wire        o_wr_en,           
    output wire [13:0] o_wr_addr,         
    output wire [23:0] o_wr_data,         
    output wire [ 2:0] o_wr_be,           

    // ---- post_process scalar ----
    input wire signed [7:0] i_final_data,  
    input  wire        i_final_valid,      
    output wire        o_final_ready,      
    output reg         o_final_tile_done,  

    // ---- Done / CSR ----
    output reg               o_layer_done,       
    input  wire              i_irq_en,           
    input  wire              i_irq_clear,        
    output reg signed [31:0] o_final_result,  
    output reg               o_done_status,      
    output wire              o_irq               
);

    // ---- cfg ----
    reg        is_final;
    reg [13:0] dst_base;
    reg [ 3:0] wpp;                         // ceil(C / 3) : C <= 32 -> 1 ~ 11
    reg        final_stored;                // Final scalar stored
    reg        layer_done_sent;             // Layer completion sent

    function [3:0] ceil_div3;               // Ceiling divide by 3
        input [5:0] c;
        begin ceil_div3 = ({2'b00, c} + 8'd2) / 8'd3; end
    endfunction

    // Intermediate-layer write path
    wire [11:0] m_pos  = i_meta[11:0];
    wire [ 4:0] m_ocb  = i_meta[16:12];
    wire        m_lend = i_meta[18];

    wire [15:0] pix_off = m_pos * {12'd0, wpp};                 // Pixel address offset
    wire [ 3:0] ch_off  = m_ocb / 5'd3;                         // Channel group offset

    assign o_ready = rst_n && !i_cfg_valid && !is_final && !layer_done_sent && i_write_grant;         // Direct write when granted
    assign o_wr_en   = i_valid && o_ready;
    assign o_wr_addr = dst_base + pix_off[13:0] + {10'd0, ch_off};
    assign o_wr_data = i_data;
    assign o_wr_be   = i_keep;

    wire wr_fire     = o_wr_en;
    wire lend_fire   = wr_fire && m_lend && !layer_done_sent;  

    assign o_final_ready = rst_n && !i_cfg_valid && is_final && !final_stored;
    wire   final_fire    = i_final_valid && o_final_ready;

    assign o_irq = i_irq_en && o_done_status;

    always @(posedge clk or negedge rst_n) begin
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

            // Layer Change : next clk = layer_done High-state
            if (lend_fire) begin
                o_layer_done    <= 1'b1;
                layer_done_sent <= 1'b1;
            end

            // Final : angle store
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