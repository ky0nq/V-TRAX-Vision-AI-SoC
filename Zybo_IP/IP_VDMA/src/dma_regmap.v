`timescale 1 ns / 1 ps

// ============================================================================
//  dma_regmap : DMA register map (a single AXI-Lite slave controls both MM2S / S2MM)
//
//  ---------------------------- MM2S (Read) ----------------------------------
//  0x00 MM2S_CR   [2]  ABORT     : writing 1 gives a 1-clock abort pulse (not stored, reads as 0)
//                 [4]  CYCLIC    : 1 = automatically start the next frame when a frame ends
//                 [5]  LIVE      : 0 = repeat fixed SA / 1 = S2MM DA[newest_idx]
//                 [6]  IDX_SW    : 0 = newest_idx from S2MM / 1 = from SW_IDX
//                 [12] IOC_IrqEn / [14] Err_IrqEn
//  0x04 MM2S_SR   [0] busy, [1] idle, [4] read_error, [10:8] cur_buf,
//                 [12] IOC_Irq (W1C), [14] Err_Irq (W1C)
//  0x18 SA        address to read when LIVE=0 (loading screen = 0x8000_0000)
//  0x1C READ_ERR  address of the first error beat (RO)
//  0x28 BTT       frame byte count; writing it starts MM2S
//  0x30 BURST_CFG [7:0] ARLEN, [9:8] burst type (00 FIXED, 01 INCR)
//  0x38 NUM_BUF   [3:0] number of buffers (max 3)
//  0x3C SW_IDX    [2:0] buffer index set by the CPU when IDX_SW=1
//
//  ---------------------------- S2MM (Write) ---------------------------------
//  0x40 S2MM_CR   [12] IOC_IrqEn / [14] Err_IrqEn
//  0x44 S2MM_SR   [0] busy, [1] idle, [4] write_error, [10:8] newest,
//                 [12] IOC_Irq (W1C), [14] Err_Irq (W1C)
//  0x48 DA0       frame buffer 0 addr ┐ S2MM writes them in order,
//  0x4C DA1       frame buffer 1 addr │ and MM2S reads these same addresses in LIVE mode
//  0x50 DA2       frame buffer 2 addr ┘ (need not be contiguous)
//  0x54 START     writing 1 to [0] starts S2MM (not stored, reads as 0)
//  0x58 WRITE_ERR address of the first error burst (RO)
//
//  Other addresses : read as 0, writes ignored
//
//  mm2s_irq = (MM2S IOC_Irq & IOC_IrqEn) | (MM2S Err_Irq & Err_IrqEn)
//  s2mm_irq = (S2MM IOC_Irq & IOC_IrqEn) | (S2MM Err_Irq & Err_IrqEn)
// ============================================================================
module dma_regmap #
(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 7          // 0x00 ~ 0x7F
)
(
    // ================= To MM2S =================
    output reg  [31:0] mm2s_cr,
    output reg  [31:0] mm2s_sa,
    output reg  [31:0] mm2s_btt,
    output reg  [9:0]  mm2s_burst_cfg,
    output reg  [3:0]  mm2s_num_buf,
    output reg  [2:0]  mm2s_sw_idx,
    output reg         mm2s_start,
    output reg         mm2s_abort,
    output wire        mm2s_irq,

    input  wire        mm2s_busy,
    input  wire        mm2s_frame_done,
    input  wire        mm2s_error,
    input  wire [31:0] mm2s_error_addr,
    input  wire [2:0]  mm2s_cur_buf,

    // ================= To S2MM =================
    output reg  [31:0] s2mm_cr,
    output reg  [31:0] s2mm_da0,
    output reg  [31:0] s2mm_da1,
    output reg  [31:0] s2mm_da2,
    output reg         s2mm_start,
    output wire        s2mm_irq,

    input  wire        s2mm_busy,
    input  wire        s2mm_frame_done,
    input  wire        s2mm_error,
    input  wire [31:0] s2mm_error_addr,
    input  wire [2:0]  s2mm_newest_idx,

    // ================= AXI-Lite =================
    input  wire                                S_AXI_ACLK,
    input  wire                                S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]     S_AXI_AWADDR,
    input  wire [2 : 0]                        S_AXI_AWPROT,
    input  wire                                S_AXI_AWVALID,
    output wire                                S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
    input  wire                                S_AXI_WVALID,
    output wire                                S_AXI_WREADY,
    output wire [1 : 0]                        S_AXI_BRESP,
    output wire                                S_AXI_BVALID,
    input  wire                                S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]     S_AXI_ARADDR,
    input  wire [2 : 0]                        S_AXI_ARPROT,
    input  wire                                S_AXI_ARVALID,
    output wire                                S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]     S_AXI_RDATA,
    output wire [1 : 0]                        S_AXI_RRESP,
    output wire                                S_AXI_RVALID,
    input  wire                                S_AXI_RREADY
);

    // ------------------------------------------------------------------
    // Addresses
    // ------------------------------------------------------------------
    // MM2S
    localparam [6:0] A_MM2S_CR   = 7'h00;
    localparam [6:0] A_MM2S_SR   = 7'h04;
    localparam [6:0] A_SA        = 7'h18;
    localparam [6:0] A_READ_ERR  = 7'h1C;
    localparam [6:0] A_BTT       = 7'h28;
    localparam [6:0] A_BURST_CFG = 7'h30;
    localparam [6:0] A_NUM_BUF   = 7'h38;
    localparam [6:0] A_SW_IDX    = 7'h3C;
    // S2MM
    localparam [6:0] A_S2MM_CR   = 7'h40;
    localparam [6:0] A_S2MM_SR   = 7'h44;
    localparam [6:0] A_DA0       = 7'h48;
    localparam [6:0] A_DA1       = 7'h4C;
    localparam [6:0] A_DA2       = 7'h50;
    localparam [6:0] A_START     = 7'h54;
    localparam [6:0] A_WRITE_ERR = 7'h58;

    // Bit positions (common to MM2S / S2MM)
    localparam CR_ABORT     = 2;
    localparam CR_IOC_IRQEN = 12;
    localparam CR_ERR_IRQEN = 14;
    localparam SR_IOC_IRQ   = 12;
    localparam SR_ERR_IRQ   = 14;

    // ------------------------------------------------------------------
    // AXI-Lite internal signals
    // ------------------------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_awaddr;
    reg                            axi_awready;
    reg                            axi_wready;
    reg [1 : 0]                    axi_bresp;
    reg                            axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_araddr;
    reg                            axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1 : 0] axi_rdata;
    reg [1 : 0]                    axi_rresp;
    reg                            axi_rvalid;

    reg [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;
    reg                          aw_en;
    wire                         slv_reg_rden;
    wire                         slv_reg_wren;

    assign slv_reg_wren = S_AXI_WREADY && S_AXI_WVALID && S_AXI_AWREADY && S_AXI_AWVALID;
    assign slv_reg_rden = S_AXI_ARREADY & S_AXI_ARVALID & ~S_AXI_RVALID;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    //======================================================
    // AWREADY / AWADDR / WREADY  (accepted together once both address and data have arrived)
    //======================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                axi_awready <= 1'b1;
                aw_en       <= 1'b0;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                aw_en       <= 1'b1;
                axi_awready <= 1'b0;
            end else begin
                axi_awready <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0)
            axi_awaddr <= 0;
        else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
            axi_awaddr <= S_AXI_AWADDR;
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    //======================================================
    // Register Write
    //======================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            // MM2S
            mm2s_cr        <= 32'd0;
            mm2s_sa        <= 32'd0;
            mm2s_btt       <= 32'd0;
            mm2s_burst_cfg <= 10'b01_0000_1111;   // Default: INCR, 16 beat
            mm2s_num_buf   <= 4'd3;
            mm2s_sw_idx    <= 3'd0;
            mm2s_start     <= 1'b0;
            mm2s_abort     <= 1'b0;
            // S2MM
            s2mm_cr        <= 32'd0;
            s2mm_da0       <= 32'd0;
            s2mm_da1       <= 32'd0;
            s2mm_da2       <= 32'd0;
            s2mm_start     <= 1'b0;
        end else begin
            // Pulses default to 0 every clock -> 1 for one clock only when the condition is met
            mm2s_start <= 1'b0;
            mm2s_abort <= 1'b0;
            s2mm_start <= 1'b0;

            if (slv_reg_wren) begin
                case (axi_awaddr)
                    // ---------------- MM2S ----------------
                    A_MM2S_CR: begin
                        mm2s_cr           <= S_AXI_WDATA;
                        mm2s_cr[CR_ABORT] <= 1'b0;                 // ABORT is not stored
                        mm2s_abort        <= S_AXI_WDATA[CR_ABORT];
                    end
                    A_SA:        mm2s_sa        <= S_AXI_WDATA;
                    A_BURST_CFG: mm2s_burst_cfg <= S_AXI_WDATA[9:0];
                    A_NUM_BUF:   mm2s_num_buf   <= S_AXI_WDATA[3:0];
                    A_SW_IDX:    mm2s_sw_idx    <= S_AXI_WDATA[2:0];
                    A_BTT: begin
                        mm2s_btt   <= S_AXI_WDATA;
                        mm2s_start <= 1'b1;                        // BTT write = MM2S start
                    end
                    // ---------------- S2MM ----------------
                    A_S2MM_CR:   s2mm_cr    <= S_AXI_WDATA;
                    A_DA0:       s2mm_da0   <= S_AXI_WDATA;
                    A_DA1:       s2mm_da1   <= S_AXI_WDATA;
                    A_DA2:       s2mm_da2   <= S_AXI_WDATA;
                    A_START:     s2mm_start <= S_AXI_WDATA[0];     // START[0] = S2MM start
                    default: ;
                endcase
            end
        end
    end

    //======================================================
    // Interrupt status (W1C, set has priority) - separate per channel
    //======================================================
    reg mm2s_error_q, s2mm_error_q;
    reg mm2s_ioc, mm2s_err;
    reg s2mm_ioc, s2mm_err;

    wire mm2s_error_rise = mm2s_error & ~mm2s_error_q;
    wire s2mm_error_rise = s2mm_error & ~s2mm_error_q;
    wire mm2s_sr_wr      = slv_reg_wren && (axi_awaddr == A_MM2S_SR);
    wire s2mm_sr_wr      = slv_reg_wren && (axi_awaddr == A_S2MM_SR);

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            mm2s_error_q <= 1'b0;  s2mm_error_q <= 1'b0;
            mm2s_ioc     <= 1'b0;  mm2s_err     <= 1'b0;
            s2mm_ioc     <= 1'b0;  s2mm_err     <= 1'b0;
        end else begin
            mm2s_error_q <= mm2s_error;
            s2mm_error_q <= s2mm_error;

            // ---- MM2S ----
            if (mm2s_frame_done)                                 mm2s_ioc <= 1'b1;
            else if (mm2s_sr_wr && S_AXI_WDATA[SR_IOC_IRQ])      mm2s_ioc <= 1'b0;

            if (mm2s_error_rise)                                 mm2s_err <= 1'b1;
            else if (mm2s_sr_wr && S_AXI_WDATA[SR_ERR_IRQ])      mm2s_err <= 1'b0;

            // ---- S2MM ----
            if (s2mm_frame_done)                                 s2mm_ioc <= 1'b1;
            else if (s2mm_sr_wr && S_AXI_WDATA[SR_IOC_IRQ])      s2mm_ioc <= 1'b0;

            if (s2mm_error_rise)                                 s2mm_err <= 1'b1;
            else if (s2mm_sr_wr && S_AXI_WDATA[SR_ERR_IRQ])      s2mm_err <= 1'b0;
        end
    end

    assign mm2s_irq = (mm2s_ioc & mm2s_cr[CR_IOC_IRQEN]) | (mm2s_err & mm2s_cr[CR_ERR_IRQEN]);
    assign s2mm_irq = (s2mm_ioc & s2mm_cr[CR_IOC_IRQEN]) | (s2mm_err & s2mm_cr[CR_ERR_IRQEN]);

    // Assemble status registers (same bit layout for MM2S / S2MM)
    wire [31:0] mm2s_sr = {17'd0, mm2s_err, 1'b0, mm2s_ioc, 1'b0, mm2s_cur_buf,
                           3'd0, mm2s_error, 2'd0, ~mm2s_busy, mm2s_busy};
    wire [31:0] s2mm_sr = {17'd0, s2mm_err, 1'b0, s2mm_ioc, 1'b0, s2mm_newest_idx,
                           3'd0, s2mm_error, 2'd0, ~s2mm_busy, s2mm_busy};

    //======================================================
    // BVALID, BRESP
    //======================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else begin
            if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b0;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    //======================================================
    // ARREADY, ARADDR
    //======================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_araddr  <= 0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    //======================================================
    // RVALID, RRESP
    //======================================================
    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b0;
        end else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b0;
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    //======================================================
    // Read mux
    //======================================================
    always @(*) begin
        case (axi_araddr)
            // MM2S
            A_MM2S_CR:   reg_data_out = mm2s_cr;
            A_MM2S_SR:   reg_data_out = mm2s_sr;
            A_SA:        reg_data_out = mm2s_sa;
            A_READ_ERR:  reg_data_out = mm2s_error_addr;
            A_BTT:       reg_data_out = mm2s_btt;
            A_BURST_CFG: reg_data_out = {22'd0, mm2s_burst_cfg};
            A_NUM_BUF:   reg_data_out = {28'd0, mm2s_num_buf};
            A_SW_IDX:    reg_data_out = {29'd0, mm2s_sw_idx};
            // S2MM
            A_S2MM_CR:   reg_data_out = s2mm_cr;
            A_S2MM_SR:   reg_data_out = s2mm_sr;
            A_DA0:       reg_data_out = s2mm_da0;
            A_DA1:       reg_data_out = s2mm_da1;
            A_DA2:       reg_data_out = s2mm_da2;
            A_WRITE_ERR: reg_data_out = s2mm_error_addr;
            default:     reg_data_out = 32'd0;
        endcase
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN == 1'b0)
            axi_rdata <= 0;
        else if (slv_reg_rden)
            axi_rdata <= reg_data_out;
    end

endmodule
