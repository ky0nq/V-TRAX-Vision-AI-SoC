`timescale 1ns / 1ps
//
// dma_top : VDMA-style DMA (MM2S + S2MM), one AXI-Lite + one register map
//
//               s_axi_lite (7bit, 0x00 ~ 0x7F)
//                      │
//                 [dma_regmap]  0x00~0x3F : MM2S registers / 0x40~0x7F : S2MM registers
//                  │        │
//  MM2S cfg/status │        │ S2MM cfg/status
//                  v        v
//      dma_mm2s_video      s_axis_video (24bit) -> s2mm_packetizer -> s2mm_write_top
//      (DDR/BRAM -> video)                                            (camera -> DDR)
//            ▲                   │
//            └ newest_idx, DA0~2 ┘   (acts as VDMA genlock : reads the buffer just finished writing)
//
// Port groups (prefixes for Vivado interface auto-inference)
//   s_axi_lite_*    : CPU register access (AXI4-Lite)
//   s_axis_video_*  : camera video input (24bit RGB, tlast = EOL)  <- AXI_GammaCorrection
//                     (the former external axis_frame_packetizer is now built in as s2mm_packetizer)
//   m_axi_s2mm_*    : DDR write (AXI3)
//   m_axi_mm2s_*    : DDR/BRAM read (AXI4)
//   m_axis_video_*  : video output (24bit RGB, tuser = SOF, tlast = EOL)
//
// Single clock aclk (all interfaces assumed to share the same clock)
//
module dma_top #(
    parameter integer PIXELS_PER_LINE = 1280,
    parameter integer FRAME_HEIGHT    = 720,
    parameter integer S2MM_FIFO_DEPTH = 1024,
    parameter integer MM2S_FIFO_DEPTH = 64
)(
    input  wire         aclk,
    input  wire         aresetn,

    output wire         mm2s_irq,
    output wire         s2mm_irq,

    // ================= S_AXI_LITE =================
    input  wire [6:0]   s_axi_lite_awaddr,
    input  wire [2:0]   s_axi_lite_awprot,
    input  wire         s_axi_lite_awvalid,
    output wire         s_axi_lite_awready,
    input  wire [31:0]  s_axi_lite_wdata,
    input  wire [3:0]   s_axi_lite_wstrb,
    input  wire         s_axi_lite_wvalid,
    output wire         s_axi_lite_wready,
    output wire [1:0]   s_axi_lite_bresp,
    output wire         s_axi_lite_bvalid,
    input  wire         s_axi_lite_bready,
    input  wire [6:0]   s_axi_lite_araddr,
    input  wire [2:0]   s_axi_lite_arprot,
    input  wire         s_axi_lite_arvalid,
    output wire         s_axi_lite_arready,
    output wire [31:0]  s_axi_lite_rdata,
    output wire [1:0]   s_axi_lite_rresp,
    output wire         s_axi_lite_rvalid,
    input  wire         s_axi_lite_rready,

    // ================= S_AXIS_VIDEO (camera video input, 24bit RGB) =================
    input  wire [23:0]  s_axis_video_tdata,
    input  wire         s_axis_video_tvalid,
    output wire         s_axis_video_tready,
    input  wire         s_axis_video_tlast,     // EOL (end of line)
    input  wire         s_axis_video_tuser,     // SOF (connected only; packetizer uses its own counter)

    // ================= M_AXI_S2MM (AXI3 write) =================
    output wire [3:0]   m_axi_s2mm_awid,
    output wire [31:0]  m_axi_s2mm_awaddr,
    output wire [3:0]   m_axi_s2mm_awlen,
    output wire [2:0]   m_axi_s2mm_awsize,
    output wire [1:0]   m_axi_s2mm_awburst,
    output wire [1:0]   m_axi_s2mm_awlock,
    output wire [3:0]   m_axi_s2mm_awcache,
    output wire [2:0]   m_axi_s2mm_awprot,
    output wire         m_axi_s2mm_awvalid,
    input  wire         m_axi_s2mm_awready,
    output wire [3:0]   m_axi_s2mm_wid,
    output wire [31:0]  m_axi_s2mm_wdata,
    output wire [3:0]   m_axi_s2mm_wstrb,
    output wire         m_axi_s2mm_wlast,
    output wire         m_axi_s2mm_wvalid,
    input  wire         m_axi_s2mm_wready,
    input  wire [3:0]   m_axi_s2mm_bid,
    input  wire [1:0]   m_axi_s2mm_bresp,
    input  wire         m_axi_s2mm_bvalid,
    output wire         m_axi_s2mm_bready,

    // ================= M_AXI_MM2S (AXI4 read) =================
    output wire [4:0]   m_axi_mm2s_arid,
    output wire [31:0]  m_axi_mm2s_araddr,
    output wire [7:0]   m_axi_mm2s_arlen,
    output wire [2:0]   m_axi_mm2s_arsize,
    output wire [1:0]   m_axi_mm2s_arburst,
    output wire         m_axi_mm2s_arlock,
    output wire [3:0]   m_axi_mm2s_arcache,
    output wire [2:0]   m_axi_mm2s_arprot,
    output wire [3:0]   m_axi_mm2s_arqos,
    output wire         m_axi_mm2s_arvalid,
    input  wire         m_axi_mm2s_arready,
    input  wire [4:0]   m_axi_mm2s_rid,
    input  wire [31:0]  m_axi_mm2s_rdata,
    input  wire [1:0]   m_axi_mm2s_rresp,
    input  wire         m_axi_mm2s_rlast,
    input  wire         m_axi_mm2s_rvalid,
    output wire         m_axi_mm2s_rready,

    // ================= M_AXIS_VIDEO (video output) =================
    output wire [23:0]  m_axis_video_tdata,
    output wire [2:0]   m_axis_video_tkeep,
    output wire         m_axis_video_tuser,
    output wire         m_axis_video_tlast,
    output wire         m_axis_video_tvalid,
    input  wire         m_axis_video_tready
);

    // ------------------------------------------------------------------
    // Register map <-> channel connection signals
    // ------------------------------------------------------------------
    // MM2S config / status
    wire [31:0] mm2s_cr, mm2s_sa, mm2s_btt;
    wire [9:0]  mm2s_burst_cfg;
    wire [3:0]  mm2s_num_buf;
    wire [2:0]  mm2s_sw_idx;
    wire        mm2s_start, mm2s_abort;
    wire        mm2s_busy, mm2s_frame_done, mm2s_error;
    wire [31:0] mm2s_error_addr;
    wire [2:0]  mm2s_cur_buf;

    // S2MM config / status
    wire [31:0] s2mm_cr, s2mm_da0, s2mm_da1, s2mm_da2;
    wire        s2mm_start;
    wire        s2mm_busy, s2mm_frame_done, s2mm_error;
    wire [31:0] s2mm_error_addr;
    wire [2:0]  s2mm_newest_idx;

    // ------------------------------------------------------------------
    // Register map (single AXI-Lite slave)
    // ------------------------------------------------------------------
    dma_regmap #(
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (7)
    ) U_REGMAP (
        .mm2s_cr         (mm2s_cr),
        .mm2s_sa         (mm2s_sa),
        .mm2s_btt        (mm2s_btt),
        .mm2s_burst_cfg  (mm2s_burst_cfg),
        .mm2s_num_buf    (mm2s_num_buf),
        .mm2s_sw_idx     (mm2s_sw_idx),
        .mm2s_start      (mm2s_start),
        .mm2s_abort      (mm2s_abort),
        .mm2s_irq        (mm2s_irq),
        .mm2s_busy       (mm2s_busy),
        .mm2s_frame_done (mm2s_frame_done),
        .mm2s_error      (mm2s_error),
        .mm2s_error_addr (mm2s_error_addr),
        .mm2s_cur_buf    (mm2s_cur_buf),

        .s2mm_cr         (s2mm_cr),
        .s2mm_da0        (s2mm_da0),
        .s2mm_da1        (s2mm_da1),
        .s2mm_da2        (s2mm_da2),
        .s2mm_start      (s2mm_start),
        .s2mm_irq        (s2mm_irq),
        .s2mm_busy       (s2mm_busy),
        .s2mm_frame_done (s2mm_frame_done),
        .s2mm_error      (s2mm_error),
        .s2mm_error_addr (s2mm_error_addr),
        .s2mm_newest_idx (s2mm_newest_idx),

        .S_AXI_ACLK      (aclk),
        .S_AXI_ARESETN   (aresetn),
        .S_AXI_AWADDR    (s_axi_lite_awaddr),
        .S_AXI_AWPROT    (s_axi_lite_awprot),
        .S_AXI_AWVALID   (s_axi_lite_awvalid),
        .S_AXI_AWREADY   (s_axi_lite_awready),
        .S_AXI_WDATA     (s_axi_lite_wdata),
        .S_AXI_WSTRB     (s_axi_lite_wstrb),
        .S_AXI_WVALID    (s_axi_lite_wvalid),
        .S_AXI_WREADY    (s_axi_lite_wready),
        .S_AXI_BRESP     (s_axi_lite_bresp),
        .S_AXI_BVALID    (s_axi_lite_bvalid),
        .S_AXI_BREADY    (s_axi_lite_bready),
        .S_AXI_ARADDR    (s_axi_lite_araddr),
        .S_AXI_ARPROT    (s_axi_lite_arprot),
        .S_AXI_ARVALID   (s_axi_lite_arvalid),
        .S_AXI_ARREADY   (s_axi_lite_arready),
        .S_AXI_RDATA     (s_axi_lite_rdata),
        .S_AXI_RRESP     (s_axi_lite_rresp),
        .S_AXI_RVALID    (s_axi_lite_rvalid),
        .S_AXI_RREADY    (s_axi_lite_rready)
    );

    // ------------------------------------------------------------------
    // Packetizer : 24bit pixel -> 32bit packed (tuser=SOF, tlast=end of frame)
    // ------------------------------------------------------------------
    wire [31:0] pk_tdata;
    wire [3:0]  pk_tkeep;
    wire [15:0] pk_tuser;
    wire        pk_tlast;
    wire        pk_tvalid;
    wire        pk_tready;

    s2mm_packetizer #(
        .TUSER_WIDTH     (16),
        .TID_WIDTH       (8),
        .TDEST_WIDTH     (4),
        .PIXELS_PER_LINE (PIXELS_PER_LINE),
        .FRAME_HEIGHT    (FRAME_HEIGHT)
    ) U_PACKETIZER (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tdata  (s_axis_video_tdata),
        .s_axis_tlast  (s_axis_video_tlast),
        .s_axis_tvalid (s_axis_video_tvalid),
        .s_axis_tready (s_axis_video_tready),
        .m_axis_tdata  (pk_tdata),
        .m_axis_tkeep  (pk_tkeep),
        .m_axis_tuser  (pk_tuser),
        .m_axis_tid    (),
        .m_axis_tdest  (),
        .m_axis_tlast  (pk_tlast),
        .m_axis_tvalid (pk_tvalid),
        .m_axis_tready (pk_tready)
    );

    // s_axis_video_tuser is for interface compatibility (packetizer generates SOF itself)
    wire _unused_video_tuser = s_axis_video_tuser;

    // ------------------------------------------------------------------
    // S2MM (camera -> DDR) : write-side top as is
    // ------------------------------------------------------------------
    s2mm_write_top #(
        .ID_WIDTH        (4),
        .ADDR_WIDTH      (32),
        .DATA_WIDTH      (32),
        .KEEP_WIDTH      (4),
        .USER_WIDTH      (16),
        .FIFO_DEPTH      (S2MM_FIFO_DEPTH),
        .BURST_LEN       (16),
        .PIXELS_PER_LINE (PIXELS_PER_LINE),
        .FRAME_HEIGHT    (FRAME_HEIGHT),
        .PIXEL_BYTES     (3)
    ) U_S2MM (
        .ACLK           (aclk),
        .ARESETN        (aresetn),

        .start          (s2mm_start),
        .base_addr0     (s2mm_da0),
        .base_addr1     (s2mm_da1),
        .base_addr2     (s2mm_da2),

        .busy           (s2mm_busy),
        .frame_done     (s2mm_frame_done),
        .newest_idx     (s2mm_newest_idx),
        .wr_error       (s2mm_error),
        .wr_error_addr  (s2mm_error_addr),

        .S_AXIS_TDATA   (pk_tdata),
        .S_AXIS_TVALID  (pk_tvalid),
        .S_AXIS_TREADY  (pk_tready),
        .S_AXIS_TLAST   (pk_tlast),
        .S_AXIS_TKEEP   (pk_tkeep),
        .S_AXIS_TUSER   (pk_tuser),

        .M_AXI_AWID     (m_axi_s2mm_awid),
        .M_AXI_AWADDR   (m_axi_s2mm_awaddr),
        .M_AXI_AWLEN    (m_axi_s2mm_awlen),
        .M_AXI_AWSIZE   (m_axi_s2mm_awsize),
        .M_AXI_AWBURST  (m_axi_s2mm_awburst),
        .M_AXI_AWLOCK   (m_axi_s2mm_awlock),
        .M_AXI_AWCACHE  (m_axi_s2mm_awcache),
        .M_AXI_AWPROT   (m_axi_s2mm_awprot),
        .M_AXI_AWVALID  (m_axi_s2mm_awvalid),
        .M_AXI_AWREADY  (m_axi_s2mm_awready),

        .M_AXI_WID      (m_axi_s2mm_wid),
        .M_AXI_WDATA    (m_axi_s2mm_wdata),
        .M_AXI_WSTRB    (m_axi_s2mm_wstrb),
        .M_AXI_WLAST    (m_axi_s2mm_wlast),
        .M_AXI_WVALID   (m_axi_s2mm_wvalid),
        .M_AXI_WREADY   (m_axi_s2mm_wready),

        .M_AXI_BID      (m_axi_s2mm_bid),
        .M_AXI_BRESP    (m_axi_s2mm_bresp),
        .M_AXI_BVALID   (m_axi_s2mm_bvalid),
        .M_AXI_BREADY   (m_axi_s2mm_bready)
    );

    // ------------------------------------------------------------------
    // MM2S (DDR/BRAM -> video)
    // ------------------------------------------------------------------
    dma_mm2s_video #(
        .FIFO_DEPTH      (MM2S_FIFO_DEPTH),
        .PIXELS_PER_LINE (PIXELS_PER_LINE),
        .FRAME_HEIGHT    (FRAME_HEIGHT)
    ) U_MM2S (
        .aclk                (aclk),
        .aresetn             (aresetn),

        .cr                  (mm2s_cr),
        .sa                  (mm2s_sa),
        .btt                 (mm2s_btt),
        .burst_cfg           (mm2s_burst_cfg),
        .num_buf             (mm2s_num_buf),
        .sw_idx              (mm2s_sw_idx),
        .start               (mm2s_start),
        .abort               (mm2s_abort),

        .busy                (mm2s_busy),
        .frame_done          (mm2s_frame_done),
        .error               (mm2s_error),
        .error_addr          (mm2s_error_addr),
        .cur_buf_idx         (mm2s_cur_buf),

        .s2mm_newest_idx     (s2mm_newest_idx),
        .s2mm_buf_addr0      (s2mm_da0),
        .s2mm_buf_addr1      (s2mm_da1),
        .s2mm_buf_addr2      (s2mm_da2),

        .m_axi_arid          (m_axi_mm2s_arid),
        .m_axi_araddr        (m_axi_mm2s_araddr),
        .m_axi_arlen         (m_axi_mm2s_arlen),
        .m_axi_arsize        (m_axi_mm2s_arsize),
        .m_axi_arburst       (m_axi_mm2s_arburst),
        .m_axi_arlock        (m_axi_mm2s_arlock),
        .m_axi_arcache       (m_axi_mm2s_arcache),
        .m_axi_arprot        (m_axi_mm2s_arprot),
        .m_axi_arqos         (m_axi_mm2s_arqos),
        .m_axi_arvalid       (m_axi_mm2s_arvalid),
        .m_axi_arready       (m_axi_mm2s_arready),
        .m_axi_rid           (m_axi_mm2s_rid),
        .m_axi_rdata         (m_axi_mm2s_rdata),
        .m_axi_rresp         (m_axi_mm2s_rresp),
        .m_axi_rlast         (m_axi_mm2s_rlast),
        .m_axi_rvalid        (m_axi_mm2s_rvalid),
        .m_axi_rready        (m_axi_mm2s_rready),

        .m_axis_video_tdata  (m_axis_video_tdata),
        .m_axis_video_tkeep  (m_axis_video_tkeep),
        .m_axis_video_tuser  (m_axis_video_tuser),
        .m_axis_video_tlast  (m_axis_video_tlast),
        .m_axis_video_tvalid (m_axis_video_tvalid),
        .m_axis_video_tready (m_axis_video_tready)
    );

endmodule
