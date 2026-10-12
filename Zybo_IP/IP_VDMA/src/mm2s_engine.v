`timescale 1ns / 1ps

module mm2s_engine #(
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter LEN_WIDTH       = 32,
    parameter BURST_WIDTH     = 8,

    parameter [ADDR_WIDTH-1:0] R0_BASE = 32'h0000_0000,   // DDR
    parameter [ADDR_WIDTH-1:0] R0_SIZE = 32'h4000_0000,
    parameter [ADDR_WIDTH-1:0] R1_BASE = 32'h4400_0000,   // BRAM frame window
    parameter [ADDR_WIDTH-1:0] R1_SIZE = 32'h002A_3000,

    parameter MAX_BURST_BYTES = 64
)(
    input                           clk,
    input                           rst_n,

    input                           start,
    input                           abort,
    input                           cyclic,
    input       [ADDR_WIDTH-1:0]    src_addr,   // Latched at init (can be updated every frame)
    input       [LEN_WIDTH-1:0]     length,
    input       [BURST_WIDTH+1:0]   burst_cfg,
    output                          busy,
    output                          done,
    output                          error,
    output      [ADDR_WIDTH-1:0]    error_addr,
    output                          frame_done,

    output                          fifo_wr_en,
    output      [DATA_WIDTH-1:0]    fifo_wr_data,
    input                           fifo_full,

    output      [4:0]               arid,
    output      [ADDR_WIDTH-1:0]    araddr,
    output      [BURST_WIDTH-1:0]   arlen,
    output      [2:0]               arsize,
    output      [1:0]               arburst,
    output                          arvalid,
    input                           arready,
    input       [DATA_WIDTH-1:0]    rdata,
    input                           rvalid,
    input                           rlast,
    input       [4:0]               rid,
    input       [1:0]               rresp,
    output                          rready
);

    wire                  en, init, xfer_done;
    wire [ADDR_WIDTH-1:0] err_addr_w;
    wire                  err_valid_w, cfg_err_w;

    mm2s_controller #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) U_READ_CNTL (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .abort      (abort),
        .cyclic     (cyclic),
        .busy       (busy),
        .done       (done),
        .error      (error),
        .error_addr (error_addr),
        .frame_done (frame_done),
        .xfer_done  (xfer_done),
        .err_valid  (err_valid_w),
        .cfg_err    (cfg_err_w),
        .err_addr   (err_addr_w),
        .en         (en),
        .init       (init)
    );

    mm2s_datapath #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LEN_WIDTH       (LEN_WIDTH),
        .BURST_WIDTH     (BURST_WIDTH),
        .R0_BASE         (R0_BASE),
        .R0_SIZE         (R0_SIZE),
        .R1_BASE         (R1_BASE),
        .R1_SIZE         (R1_SIZE),
        .MAX_BURST_BYTES (MAX_BURST_BYTES)
    ) U_READ_DATAPATH (
        .clk          (clk),
        .rst_n        (rst_n),
        .en           (en),
        .init         (init),
        .abort        (abort),
        .src_addr     (src_addr),
        .length       (length),
        .burst_cfg    (burst_cfg),
        .r_hs         (),
        .xfer_done    (xfer_done),
        .err_addr     (err_addr_w),
        .err_valid    (err_valid_w),
        .cfg_err      (cfg_err_w),
        .fifo_wr_en   (fifo_wr_en),
        .fifo_wr_data (fifo_wr_data),
        .fifo_full    (fifo_full),
        .arid         (arid),
        .araddr       (araddr),
        .arlen        (arlen),
        .arsize       (arsize),
        .arburst      (arburst),
        .arvalid      (arvalid),
        .arready      (arready),
        .rdata        (rdata),
        .rvalid       (rvalid),
        .rid          (rid),
        .rlast        (rlast),
        .rresp        (rresp),
        .rready       (rready)
    );

endmodule