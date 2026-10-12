`timescale 1ns / 1ps
//
// s2mm_write_top (S2MM : camera stream -> DDR)
//
// [Changes from the previous version]
//   - base_addr[0:2] array port -> base_addr0/1/2
//   - Removed the trailing comma in the port list
//   - Pass through the write engine status outputs (busy, frame_done, newest_idx, wr_error, wr_error_addr)
//
module s2mm_write_top #(
    parameter ID_WIDTH        = 4,
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter KEEP_WIDTH      = DATA_WIDTH / 8,
    parameter USER_WIDTH      = 16,
    parameter FIFO_DEPTH      = 1024,
    parameter BURST_LEN       = 16,
    parameter PIXELS_PER_LINE = 1280,
    parameter FRAME_HEIGHT    = 720,
    parameter PIXEL_BYTES     = 3
)(
    input  wire                         ACLK,
    input  wire                         ARESETN,

    input  wire                         start,
    input  wire [ADDR_WIDTH-1:0]        base_addr0,
    input  wire [ADDR_WIDTH-1:0]        base_addr1,
    input  wire [ADDR_WIDTH-1:0]        base_addr2,

    output wire                         busy,
    output wire                         frame_done,
    output wire [2:0]                   newest_idx,
    output wire                         wr_error,
    output wire [ADDR_WIDTH-1:0]        wr_error_addr,

    input  wire [DATA_WIDTH-1:0]        S_AXIS_TDATA,
    input  wire                         S_AXIS_TVALID,
    output wire                         S_AXIS_TREADY,
    input  wire                         S_AXIS_TLAST,
    input  wire [KEEP_WIDTH-1:0]        S_AXIS_TKEEP,
    input  wire [USER_WIDTH-1:0]        S_AXIS_TUSER,

    output wire [ID_WIDTH-1:0]          M_AXI_AWID,
    output wire [ADDR_WIDTH-1:0]        M_AXI_AWADDR,
    output wire [3:0]                   M_AXI_AWLEN,
    output wire [2:0]                   M_AXI_AWSIZE,
    output wire [1:0]                   M_AXI_AWBURST,
    output wire [1:0]                   M_AXI_AWLOCK,
    output wire [3:0]                   M_AXI_AWCACHE,
    output wire [2:0]                   M_AXI_AWPROT,
    output wire                         M_AXI_AWVALID,
    input  wire                         M_AXI_AWREADY,

    output wire [ID_WIDTH-1:0]          M_AXI_WID,
    output wire [DATA_WIDTH-1:0]        M_AXI_WDATA,
    output wire [(DATA_WIDTH/8)-1:0]    M_AXI_WSTRB,
    output wire                         M_AXI_WLAST,
    output wire                         M_AXI_WVALID,
    input  wire                         M_AXI_WREADY,

    input  wire [ID_WIDTH-1:0]          M_AXI_BID,
    input  wire [1:0]                   M_AXI_BRESP,
    input  wire                         M_AXI_BVALID,
    output wire                         M_AXI_BREADY
);

    localparam FIFO_COUNT_WIDTH = $clog2(FIFO_DEPTH+1);

    wire                         fifo_we;
    wire [DATA_WIDTH-1:0]        fifo_wdata;
    wire                         fifo_full;
    wire                         fifo_rd_en;
    wire [DATA_WIDTH-1:0]        fifo_rd_data;
    wire                         fifo_empty;
    wire [FIFO_COUNT_WIDTH-1:0]  fifo_count;

    s2mm_stream_in #(
        .DATA_WIDTH (DATA_WIDTH),
        .KEEP_WIDTH (KEEP_WIDTH),
        .USER_WIDTH (USER_WIDTH)
    ) u_dma_write_stream (
        .ACLK          (ACLK),
        .ARESETN       (ARESETN),
        .S_AXIS_TDATA  (S_AXIS_TDATA),
        .S_AXIS_TVALID (S_AXIS_TVALID),
        .S_AXIS_TREADY (S_AXIS_TREADY),
        .S_AXIS_TLAST  (S_AXIS_TLAST),
        .S_AXIS_TKEEP  (S_AXIS_TKEEP),
        .S_AXIS_TUSER  (S_AXIS_TUSER),
        .fifo_full     (fifo_full),
        .fifo_we       (fifo_we),
        .fifo_wdata    (fifo_wdata)
    );

    s2mm_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (FIFO_DEPTH)
    ) u_dma_fifo (
        .clk     (ACLK),
        .resetn  (ARESETN),
        .wr_en   (fifo_we),
        .wr_data (fifo_wdata),
        .full    (fifo_full),
        .rd_en   (fifo_rd_en),
        .rd_data (fifo_rd_data),
        .empty   (fifo_empty),
        .count   (fifo_count)
    );

    s2mm_axi_writer #(
        .ID_WIDTH        (ID_WIDTH),
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .FIFO_DEPTH      (FIFO_DEPTH),
        .BURST_LEN       (BURST_LEN),
        .PIXELS_PER_LINE (PIXELS_PER_LINE),
        .FRAME_HEIGHT    (FRAME_HEIGHT),
        .PIXEL_BYTES     (PIXEL_BYTES)
    ) u_dma_write_axi (
        .ACLK          (ACLK),
        .ARESETN       (ARESETN),

        .start         (start),
        .base_addr0    (base_addr0),
        .base_addr1    (base_addr1),
        .base_addr2    (base_addr2),

        .busy          (busy),
        .frame_done    (frame_done),
        .newest_idx    (newest_idx),
        .wr_error      (wr_error),
        .wr_error_addr (wr_error_addr),

        .fifo_empty    (fifo_empty),
        .fifo_count    (fifo_count),
        .fifo_rd_data  (fifo_rd_data),
        .fifo_rd_en    (fifo_rd_en),

        .M_AXI_AWID    (M_AXI_AWID),
        .M_AXI_AWADDR  (M_AXI_AWADDR),
        .M_AXI_AWLEN   (M_AXI_AWLEN),
        .M_AXI_AWSIZE  (M_AXI_AWSIZE),
        .M_AXI_AWBURST (M_AXI_AWBURST),
        .M_AXI_AWLOCK  (M_AXI_AWLOCK),
        .M_AXI_AWCACHE (M_AXI_AWCACHE),
        .M_AXI_AWPROT  (M_AXI_AWPROT),
        .M_AXI_AWVALID (M_AXI_AWVALID),
        .M_AXI_AWREADY (M_AXI_AWREADY),

        .M_AXI_WID     (M_AXI_WID),
        .M_AXI_WDATA   (M_AXI_WDATA),
        .M_AXI_WSTRB   (M_AXI_WSTRB),
        .M_AXI_WLAST   (M_AXI_WLAST),
        .M_AXI_WVALID  (M_AXI_WVALID),
        .M_AXI_WREADY  (M_AXI_WREADY),

        .M_AXI_BID     (M_AXI_BID),
        .M_AXI_BRESP   (M_AXI_BRESP),
        .M_AXI_BVALID  (M_AXI_BVALID),
        .M_AXI_BREADY  (M_AXI_BREADY)
    );

endmodule
