`timescale 1ns / 1ps
//
// dma_mm2s : Read channel (replaces MCDMA MM2S)
//
//   dma_regmap --(config/pulses)--> [frame select]  LIVE=0 : SA
//                                      |          LIVE=1 : S2MM DA[newest_idx]
//                                      v
//                                 mm2s_engine --(M_AXI AR/R, 32bit addr)--> axi_mem_intercon
//                                      |                                    ├─ HP0 (DDR)
//                                      v                                    └─ axi_bram_ctrl (loading screen)
//                                 mm2s_fifo (32bit)
//                                      v
//                                 M_AXIS (32bit packed) --> mm2s_depacketizer
//
// [Differences from the previous version]
//   The register map (AXI-Lite) moved up to dma_regmap in dma_top,
//   so this module receives config values as wires and returns status as wires. The rest of the logic is the same.
//
// Operation summary
//   - CYCLIC=1 : when a frame ends, start the next frame immediately without CPU intervention
//   - LIVE=0   : repeat a single SA (loading screen 0x8000_0000, frozen filter result, etc.)
//   - LIVE=1   : at the start of every frame, read the buffer most recently completed by S2MM (DA[newest_idx])
//   - LIVE / SA changes take effect automatically at the next frame boundary
//
// Single clock: aclk
//
module dma_mm2s #(
    parameter integer FIFO_DEPTH      = 64,
    parameter integer MAX_BURST_BYTES = 64
)(
    input  wire         aclk,
    input  wire         aresetn,

    // ================= Config from dma_regmap =================
    input  wire [31:0]  cr,               // MM2S_CR  ([4] CYCLIC, [5] LIVE, [6] IDX_SW)
    input  wire [31:0]  sa,               // SA
    input  wire [31:0]  btt,              // BTT
    input  wire [9:0]   burst_cfg,        // BURST_CFG
    input  wire [3:0]   num_buf,          // NUM_BUF
    input  wire [2:0]   sw_idx,           // SW_IDX
    input  wire         start,            // BTT write pulse
    input  wire         abort,            // CR.ABORT pulse

    // ================= Status to dma_regmap =================
    output wire         busy,
    output wire         frame_done,
    output wire         error,
    output wire [31:0]  error_addr,
    output reg  [2:0]   cur_buf_idx,

    // ================= Info from S2MM =================
    input  wire [2:0]   s2mm_newest_idx,  // Index of the buffer just finished writing
    input  wire [31:0]  s2mm_buf_addr0,   // DA0
    input  wire [31:0]  s2mm_buf_addr1,   // DA1
    input  wire [31:0]  s2mm_buf_addr2,   // DA2

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

    // ================= M_AXIS (32bit packed bytes) =================
    output wire [31:0]  m_axis_tdata,
    output wire [3:0]   m_axis_tkeep,
    output wire         m_axis_tlast,
    output wire         m_axis_tvalid,
    input  wire         m_axis_tready
);

    // ------------------------------------------------------------------
    // Port -> internal name (the logic below keeps the same names as the previous version)
    // ------------------------------------------------------------------
    wire [31:0] CDMACR_reg    = cr;
    wire [31:0] SA_reg        = sa;
    wire [31:0] BTT_reg       = btt;
    wire [9:0]  BURST_CFG_reg = burst_cfg;
    wire [3:0]  NUM_BUF_reg   = num_buf;
    wire [2:0]  SW_IDX_reg    = sw_idx;
    wire        start_pulse   = start;
    wire        abort_pulse   = abort;

    wire        dma_busy, dma_done, dma_error;
    wire [31:0] dma_error_addr;

    assign busy       = dma_busy;
    assign error      = dma_error;
    assign error_addr = dma_error_addr;

    // ------------------------------------------------------------------
    // Frame select (plays the role of newest_rx_idx / mm2s_override in the MCDMA ISR)
    // ------------------------------------------------------------------
    wire cr_cyclic = CDMACR_reg[4];
    wire cr_live   = CDMACR_reg[5];
    wire cr_idx_sw = CDMACR_reg[6];

    wire [2:0] newest_raw = cr_idx_sw ? SW_IDX_reg : s2mm_newest_idx;
    wire [2:0] newest_idx = ({1'b0, newest_raw} < NUM_BUF_reg) ? newest_raw : 3'd0;

    // Buffer addresses use S2MM's DA0~2 directly (FB_BASE register is unused)
    wire [31:0] live_addr = (newest_idx == 3'd0) ? s2mm_buf_addr0 :
                            (newest_idx == 3'd1) ? s2mm_buf_addr1 :
                                                   s2mm_buf_addr2;
    wire [31:0] frame_src = cr_live ? live_addr : SA_reg;

    // Index of the buffer currently being read (for debugging, SR[10:8])
    // Captured on the same clock in which the datapath latches src_addr (init)
    reg start_q;
    always @(posedge aclk) begin
        if (!aresetn) begin
            start_q     <= 1'b0;
            cur_buf_idx <= 3'd0;
        end else begin
            start_q <= start_pulse && !dma_busy;
            if (start_q || frame_done)
                cur_buf_idx <= newest_idx;
        end
    end

    // ------------------------------------------------------------------
    // Read Engine
    // ------------------------------------------------------------------
    wire        fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire        fifo_full;

    mm2s_engine #(
        .ADDR_WIDTH      (32),
        .DATA_WIDTH      (32),
        .LEN_WIDTH       (32),
        .BURST_WIDTH     (8),
        .R0_BASE         (32'h0000_0000),   // DDR (HP0)
        .R0_SIZE         (32'h4000_0000),
        .R1_BASE         (32'h8000_0000),   // BRAM frame window (axi_bram_ctrl)
        .R1_SIZE         (32'h002A_3000),   // 1280 x 720 x 3-byte BRAM frame window
        .MAX_BURST_BYTES (MAX_BURST_BYTES)
    ) U_READ_ENGINE (
        .clk          (aclk),
        .rst_n        (aresetn),
        .start        (start_pulse),
        .abort        (abort_pulse),
        .cyclic       (cr_cyclic),
        .src_addr     (frame_src),
        .length       (BTT_reg),
        .burst_cfg    (BURST_CFG_reg),
        .busy         (dma_busy),
        .done         (dma_done),
        .error        (dma_error),
        .error_addr   (dma_error_addr),
        .frame_done   (frame_done),
        .fifo_wr_en   (fifo_wr_en),
        .fifo_wr_data (fifo_wr_data),
        .fifo_full    (fifo_full),
        .arid         (m_axi_arid),
        .araddr       (m_axi_araddr),
        .arlen        (m_axi_arlen),
        .arsize       (m_axi_arsize),
        .arburst      (m_axi_arburst),
        .arvalid      (m_axi_arvalid),
        .arready      (m_axi_arready),
        .rdata        (m_axi_rdata),
        .rvalid       (m_axi_rvalid),
        .rlast        (m_axi_rlast),
        .rid          (m_axi_rid),
        .rresp        (m_axi_rresp),
        .rready       (m_axi_rready)
    );

    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;

    // ------------------------------------------------------------------
    // FIFO
    // ------------------------------------------------------------------
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_empty;

    mm2s_fifo #(
        .DATA_WIDTH (32),
        .DEPTH      (FIFO_DEPTH)
    ) U_FIFO (
        .clk          (aclk),
        .rst_n        (aresetn),
        .fifo_wr_en   (fifo_wr_en),
        .fifo_wr_data (fifo_wr_data),
        .fifo_full    (fifo_full),
        .fifo_rd_en   (fifo_rd_en),
        .fifo_rd_data (fifo_rd_data),
        .fifo_empty   (fifo_empty),
        .fifo_count   ()
    );

    // ------------------------------------------------------------------
    // FIFO -> AXI-Stream
    // ------------------------------------------------------------------
    assign m_axis_tvalid = !fifo_empty;
    assign m_axis_tdata  = fifo_rd_data;
    assign m_axis_tkeep  = 4'b1111;
    assign fifo_rd_en    = m_axis_tvalid && m_axis_tready;

    reg [29:0] out_beat_cnt;
    reg [29:0] total_beats_q;

    always @(posedge aclk) begin
        if (!aresetn)
            total_beats_q <= 30'd0;
        else if (start_pulse && !dma_busy)
            total_beats_q <= BTT_reg[31:2];
    end

    assign m_axis_tlast = (out_beat_cnt == total_beats_q - 1'b1);

    always @(posedge aclk) begin
        if (!aresetn)
            out_beat_cnt <= 30'd0;
        else if (fifo_rd_en)
            out_beat_cnt <= m_axis_tlast ? 30'd0 : out_beat_cnt + 1'b1;
    end

endmodule
