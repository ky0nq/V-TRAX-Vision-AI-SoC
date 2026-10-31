`timescale 1ns / 1ps

// pe_core: act/wgt skew buffers feeding a 3x3 systolic PE array
module pe_core (
    input logic clk,
    input logic rst_n,

    input logic [23:0] i_act_data,
    input logic        i_act_valid,

    output logic o_act_ready,

    input  logic [23:0] i_wgt_data,
    input  logic        i_wgt_valid,

    output logic o_wgt_ready,

    input logic i_step_en,
    input logic i_feed_valid,

    input logic       i_askew_clear,
    input logic       i_wskew_clear,
    input logic       i_acc_clear,
    input logic [8:0] i_mac_valid,
    input logic [8:0] i_mac_last,

    output logic [287:0] o_result_data,
    output logic [  8:0] o_result_valid
);
    logic [23:0] act_data, wgt_data;

    act_skew u_act_skew (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_clear     (i_askew_clear),
        .i_data      (i_act_data),
        .i_valid     (i_act_valid),
        .o_ready     (o_act_ready),
        .i_step_en   (i_step_en),
        .i_feed_valid(i_feed_valid),
        .o_data      (act_data)
    );

    wgt_skew u_wgt_skew (
        .clk         (clk),
        .rst_n       (rst_n),
        .i_clear     (i_wskew_clear),
        .i_data      (i_wgt_data),
        .i_valid     (i_wgt_valid),
        .o_ready     (o_wgt_ready),
        .i_step_en   (i_step_en),
        .i_feed_valid(i_feed_valid),
        .o_data      (wgt_data)
    );

    pe_array u_pe_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_act_data    (act_data),
        .i_wgt_data    (wgt_data),
        .i_mac_valid   (i_mac_valid),
        .i_mac_last    (i_mac_last),
        .o_result_data (o_result_data),
        .o_result_valid(o_result_valid)
    );
endmodule

// single_pe: int8 x int8 MAC into 32b accumulator
module single_pe (
    input logic clk,
    input logic rst_n,
    input logic i_step_en,
    input logic i_acc_clear,
    input logic i_mac_valid,
    input logic i_mac_last,

    input logic signed [7:0] act_in,
    input logic signed [7:0] weight_in,

    output logic signed [ 7:0] act_out,
    output logic signed [ 7:0] weight_out,
    output logic signed [31:0] result_data,
    output logic               o_result_valid
);

    logic signed [31:0] acc_reg;

    // 2-stage MAC for timing: product registered on step, accumulated next clk (stall-safe).
    // Result pulse is 2 clk after the last MAC edge.
    logic signed [15:0] product_q;
    logic               pq_valid;
    logic               pq_last;
    logic signed [31:0] acc_next;
    assign acc_next = acc_reg + {{16{product_q[15]}}, product_q};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_reg        <= 32'd0;
            result_data    <= 32'd0;
            o_result_valid <= 1'b0;
            act_out        <= 8'd0;
            weight_out     <= 8'd0;
            product_q      <= 16'd0;
            pq_valid       <= 1'b0;
            pq_last        <= 1'b0;
        end else begin
            if (i_acc_clear) begin
                acc_reg        <= 32'd0;
                result_data    <= 32'd0;
                o_result_valid <= 1'b0;
                pq_valid       <= 1'b0;
                pq_last        <= 1'b0;
            end else begin
                o_result_valid <= 1'b0;

                // Stage 1: capture product and valid/last on step
                pq_valid <= i_step_en && i_mac_valid;
                pq_last  <= i_step_en && i_mac_valid && i_mac_last;
                if (i_step_en) begin
                    act_out    <= act_in;
                    weight_out <= weight_in;
                    product_q  <= $signed(act_in) * $signed(weight_in);
                end

                // Stage 2: accumulate
                if (pq_valid) begin
                    acc_reg <= acc_next;
                    if (pq_last) begin
                        result_data    <= acc_next;
                        o_result_valid <= 1'b1;
                    end
                end
            end
        end
    end
endmodule

// pe_array: 3x3 PEs, PE(r,c) = index r*3+c; result_data 9 x 32b
module pe_array (
    input logic clk,
    input logic rst_n,

    input logic i_step_en,
    input logic i_acc_clear,

    input logic [23:0] i_act_data,
    input logic [23:0] i_wgt_data,

    input logic [8:0] i_mac_valid,
    input logic [8:0] i_mac_last,

    output logic [287:0] o_result_data,
    output logic [8:0] o_result_valid
);
    // act flows along a row, weight flows down a column
    logic signed [7:0] act_00_01;
    logic signed [7:0] act_01_02;

    logic signed [7:0] act_10_11;
    logic signed [7:0] act_11_12;

    logic signed [7:0] act_20_21;
    logic signed [7:0] act_21_22;

    logic signed [7:0] weight_00_10;
    logic signed [7:0] weight_10_20;

    logic signed [7:0] weight_01_11;
    logic signed [7:0] weight_11_21;

    logic signed [7:0] weight_02_12;
    logic signed [7:0] weight_12_22;

    single_pe u_single_pe00 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[0]),
        .i_mac_last    (i_mac_last[0]),
        .act_in        (i_act_data[7:0]),
        .weight_in     (i_wgt_data[7:0]),
        .act_out       (act_00_01),
        .weight_out    (weight_00_10),
        .result_data   (o_result_data[31:0]),
        .o_result_valid(o_result_valid[0])
    );

    single_pe u_single_pe01 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[1]),
        .i_mac_last    (i_mac_last[1]),
        .act_in        (act_00_01),
        .weight_in     (i_wgt_data[15:8]),
        .act_out       (act_01_02),
        .weight_out    (weight_01_11),
        .result_data   (o_result_data[63:32]),
        .o_result_valid(o_result_valid[1])
    );

    single_pe u_single_pe02 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[2]),
        .i_mac_last    (i_mac_last[2]),
        .act_in        (act_01_02),
        .weight_in     (i_wgt_data[23:16]),
        .act_out       (),
        .weight_out    (weight_02_12),
        .result_data   (o_result_data[95:64]),
        .o_result_valid(o_result_valid[2])
    );

    single_pe u_single_pe10 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[3]),
        .i_mac_last    (i_mac_last[3]),
        .act_in        (i_act_data[15:8]),
        .weight_in     (weight_00_10),
        .act_out       (act_10_11),
        .weight_out    (weight_10_20),
        .result_data   (o_result_data[127:96]),
        .o_result_valid(o_result_valid[3])
    );

    single_pe u_single_pe11 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[4]),
        .i_mac_last    (i_mac_last[4]),
        .act_in        (act_10_11),
        .weight_in     (weight_01_11),
        .act_out       (act_11_12),
        .weight_out    (weight_11_21),
        .result_data   (o_result_data[159:128]),
        .o_result_valid(o_result_valid[4])
    );

    single_pe u_single_pe12 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[5]),
        .i_mac_last    (i_mac_last[5]),
        .act_in        (act_11_12),
        .weight_in     (weight_02_12),
        .act_out       (),
        .weight_out    (weight_12_22),
        .result_data   (o_result_data[191:160]),
        .o_result_valid(o_result_valid[5])
    );

    single_pe u_single_pe20 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[6]),
        .i_mac_last    (i_mac_last[6]),
        .act_in        (i_act_data[23:16]),
        .weight_in     (weight_10_20),
        .act_out       (act_20_21),
        .weight_out    (),
        .result_data   (o_result_data[223:192]),
        .o_result_valid(o_result_valid[6])
    );

    single_pe u_single_pe21 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[7]),
        .i_mac_last    (i_mac_last[7]),
        .act_in        (act_20_21),
        .weight_in     (weight_11_21),
        .act_out       (act_21_22),
        .weight_out    (),
        .result_data   (o_result_data[255:224]),
        .o_result_valid(o_result_valid[7])
    );

    single_pe u_single_pe22 (
        .clk           (clk),
        .rst_n         (rst_n),
        .i_step_en     (i_step_en),
        .i_acc_clear   (i_acc_clear),
        .i_mac_valid   (i_mac_valid[8]),
        .i_mac_last    (i_mac_last[8]),
        .act_in        (act_21_22),
        .weight_in     (weight_12_22),
        .act_out       (),
        .weight_out    (),
        .result_data   (o_result_data[287:256]),
        .o_result_valid(o_result_valid[8])
    );
endmodule

// act_skew: per-lane delay; lane n = n+1 stages
module act_skew (
    input logic clk,
    input logic rst_n,

    input logic        i_clear,
    input logic [23:0] i_data,
    input logic        i_valid,

    output logic o_ready,

    input logic i_step_en,
    input logic i_feed_valid,

    output logic [23:0] o_data
);
    // PE(r,c) sees beat k at step k+1+r+c, matching pe_cntl mac_valid
    logic [7:0] data_d0_1, data_d1_1, data_d1_2, data_d2_1, data_d2_2, data_d2_3;

    logic [23:0] feed_data;

    assign o_ready   = rst_n && !i_clear && i_step_en && i_feed_valid;

    assign feed_data = (i_feed_valid && i_valid) ? i_data : 24'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_d0_1 <= 8'd0; data_d1_1 <= 8'd0; data_d1_2 <= 8'd0;
            data_d2_1 <= 8'd0; data_d2_2 <= 8'd0; data_d2_3 <= 8'd0;
        end else begin
            if (i_clear) begin
                data_d0_1 <= 8'd0; data_d1_1 <= 8'd0; data_d1_2 <= 8'd0;
                data_d2_1 <= 8'd0; data_d2_2 <= 8'd0; data_d2_3 <= 8'd0;
            end else begin
                if (i_step_en) begin
                    data_d0_1 <= feed_data[7:0];
                    data_d1_1 <= feed_data[15:8];   data_d1_2 <= data_d1_1;
                    data_d2_1 <= feed_data[23:16];  data_d2_2 <= data_d2_1;  data_d2_3 <= data_d2_2;
                end
            end
        end
    end

    // No output zeroing mux (timing); clear is done in the registers
    assign o_data = {data_d2_3, data_d1_2, data_d0_1};
endmodule

// wgt_skew: per-lane delay; lane n = n+1 stages
module wgt_skew (
    input logic clk,
    input logic rst_n,

    input logic        i_clear,
    input logic [23:0] i_data,
    input logic        i_valid,

    output logic o_ready,

    input logic i_step_en,
    input logic i_feed_valid,

    output logic [23:0] o_data
);
    // PE(r,c) sees beat k at step k+1+r+c, matching pe_cntl mac_valid
    logic [7:0] data_d0_1, data_d1_1, data_d1_2, data_d2_1, data_d2_2, data_d2_3;

    logic [23:0] feed_data;

    assign o_ready   = rst_n && !i_clear && i_step_en && i_feed_valid;

    assign feed_data = (i_feed_valid && i_valid) ? i_data : 24'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_d0_1 <= 8'd0; data_d1_1 <= 8'd0; data_d1_2 <= 8'd0;
            data_d2_1 <= 8'd0; data_d2_2 <= 8'd0; data_d2_3 <= 8'd0;
        end else begin
            if (i_clear) begin
                data_d0_1 <= 8'd0; data_d1_1 <= 8'd0; data_d1_2 <= 8'd0;
                data_d2_1 <= 8'd0; data_d2_2 <= 8'd0; data_d2_3 <= 8'd0;
            end else begin
                if (i_step_en) begin
                    data_d0_1 <= feed_data[7:0];
                    data_d1_1 <= feed_data[15:8];   data_d1_2 <= data_d1_1;
                    data_d2_1 <= feed_data[23:16];  data_d2_2 <= data_d2_1;  data_d2_3 <= data_d2_2;
                end
            end
        end
    end

    // No output zeroing mux (timing); clear is done in the registers
    assign o_data = {data_d2_3, data_d1_2, data_d0_1};
endmodule
