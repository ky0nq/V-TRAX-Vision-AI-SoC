`timescale 1ns / 1ps
//
// dma_mm2s_video = dma_mm2s + mm2s_depacketizer
//
//   dma_regmap --(config)--> dma_mm2s --(M_AXI)--> axi_mem_intercon (DDR / BRAM)
//                              |
//                              | 32bit packed bytes (internal connection)
//                              v
//                     mm2s_depacketizer
//                              |
//                              v
//                     M_AXIS_VIDEO (24bit RGB, 1 pixel/beat) --> v_axi4s_vid_out.video_in
//
//   Output stream convention (AXI4-Stream Video)
//     tuser : first pixel of frame (SOF)
//     tlast : last pixel of line (EOL)
//
module dma_mm2s_video #(
    parameter integer FIFO_DEPTH      = 64,
    parameter integer MAX_BURST_BYTES = 64,
    parameter integer PIXELS_PER_LINE = 1280,
    parameter integer FRAME_HEIGHT    = 720
)(
    input  wire         aclk,
    input  wire         aresetn,

    // ================= Config from dma_regmap =================
    input  wire [31:0]  cr,
    input  wire [31:0]  sa,
    input  wire [31:0]  btt,
    input  wire [9:0]   burst_cfg,
    input  wire [3:0]   num_buf,
    input  wire [2:0]   sw_idx,
    input  wire         start,
    input  wire         abort,

    // ================= Status to dma_regmap =================
    output wire         busy,
    output wire         frame_done,
    output wire         error,
    output wire [31:0]  error_addr,
    output wire [2:0]   cur_buf_idx,

    // ================= Info from S2MM =================
    input  wire [2:0]   s2mm_newest_idx,
    input  wire [31:0]  s2mm_buf_addr0,
    input  wire [31:0]  s2mm_buf_addr1,
    input  wire [31:0]  s2mm_buf_addr2,

    // ================= M_AXI (AXI4-Full, read only) =================
    output wire [4:0]   m_axi_arid,
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arlock,
    output wire [3:0]   m_axi_arcache,
    output wire [2:0]   m_axi_arprot,
    output wire [3:0]   m_axi_arqos,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [4:0]   m_axi_rid,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,

    // ================= M_AXIS_VIDEO (24bit RGB pixel) =================
    output wire [23:0]  m_axis_video_tdata,
    output wire [2:0]   m_axis_video_tkeep,
    output wire         m_axis_video_tuser,
    output wire         m_axis_video_tlast,
    output wire         m_axis_video_tvalid,
    input  wire         m_axis_video_tready
);

    // Internal 32bit packed stream (dma_mm2s -> depacketizer)
    wire [31:0] pk_tdata;
    wire [3:0]  pk_tkeep;
    wire        pk_tlast;
    wire        pk_tvalid;
    wire        pk_tready;

    dma_mm2s #(
        .FIFO_DEPTH      (FIFO_DEPTH),
        .MAX_BURST_BYTES (MAX_BURST_BYTES)
    ) U_DMA_MM2S (
        .aclk            (aclk),
        .aresetn         (aresetn),

        .cr              (cr),
        .sa              (sa),
        .btt             (btt),
        .burst_cfg       (burst_cfg),
        .num_buf         (num_buf),
        .sw_idx          (sw_idx),
        .start           (start),
        .abort           (abort),

        .busy            (busy),
        .frame_done      (frame_done),
        .error           (error),
        .error_addr      (error_addr),
        .cur_buf_idx     (cur_buf_idx),

        .s2mm_newest_idx (s2mm_newest_idx),
        .s2mm_buf_addr0  (s2mm_buf_addr0),
        .s2mm_buf_addr1  (s2mm_buf_addr1),
        .s2mm_buf_addr2  (s2mm_buf_addr2),

        .m_axi_arid      (m_axi_arid),
        .m_axi_araddr    (m_axi_araddr),
        .m_axi_arlen     (m_axi_arlen),
        .m_axi_arsize    (m_axi_arsize),
        .m_axi_arburst   (m_axi_arburst),
        .m_axi_arlock    (m_axi_arlock),
        .m_axi_arcache   (m_axi_arcache),
        .m_axi_arprot    (m_axi_arprot),
        .m_axi_arqos     (m_axi_arqos),
        .m_axi_arvalid   (m_axi_arvalid),
        .m_axi_arready   (m_axi_arready),
        .m_axi_rid       (m_axi_rid),
        .m_axi_rdata     (m_axi_rdata),
        .m_axi_rresp     (m_axi_rresp),
        .m_axi_rlast     (m_axi_rlast),
        .m_axi_rvalid    (m_axi_rvalid),
        .m_axi_rready    (m_axi_rready),

        .m_axis_tdata    (pk_tdata),
        .m_axis_tkeep    (pk_tkeep),
        .m_axis_tlast    (pk_tlast),
        .m_axis_tvalid   (pk_tvalid),
        .m_axis_tready   (pk_tready)
    );

    mm2s_depacketizer #(
        .TUSER_WIDTH     (16),
        .TID_WIDTH       (8),
        .TDEST_WIDTH     (4),
        .PIXELS_PER_LINE (PIXELS_PER_LINE),
        .FRAME_HEIGHT    (FRAME_HEIGHT)
    ) U_DEPACKETIZER (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tdata  (pk_tdata),
        .s_axis_tkeep  (pk_tkeep),
        .s_axis_tuser  (16'd0),
        .s_axis_tid    (8'd0),
        .s_axis_tdest  (4'd0),
        .s_axis_tlast  (pk_tlast),
        .s_axis_tvalid (pk_tvalid),
        .s_axis_tready (pk_tready),

        .m_axis_tdata  (m_axis_video_tdata),
        .m_axis_tkeep  (m_axis_video_tkeep),
        .m_axis_tuser  (m_axis_video_tuser),
        .m_axis_tlast  (m_axis_video_tlast),
        .m_axis_tvalid (m_axis_video_tvalid),
        .m_axis_tready (m_axis_video_tready)
    );

endmodule
