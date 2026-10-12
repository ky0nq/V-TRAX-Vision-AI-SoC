`timescale 1ns / 1ps
//
// tb_dma_top : functional check of the full DMA (S2MM + MM2S + register map)
//
//  Components
//   - AXI-Lite master task (CPU)            : register write/read (0x00 ~ 0x7F)
//   - Camera stream generator               : tuser[0]=SOF per frame, tlast on the last word
//   - AXI3 write slave (DDR)                : actually stores the data written by S2MM in a memory array
//   - AXI4 read slave (DDR + BRAM window)   : DDR returns stored values, BRAM window returns the loading-screen pattern
//   - Video output checker (vid_out)        : random tready, checks pixel values/tuser/tlast
//
//  Data rule : for byte offset o within a frame and tag t,  byte = (o*7 + t*40) & 0xFF
//     t = 0..5 : camera frame (frame number % 6)
//     t = 6    : BRAM loading screen
//   -> first byte of output frame / 40 = tag = which source the frame came from
//
//  Resolution : 64 x 4 (the writer requires each line to be a multiple of 64 bytes : 64px x 3B = 192B = 3 bursts)
//
//  Scenario
//   T0 : start S2MM (DA0/1/2 at deliberately separated addresses) + start the camera stream
//   T1 : MM2S loading screen loop (LIVE=0, SA = BRAM)    -> tag 6 repeats
//   T2 : switch to LIVE=1                                -> changes to camera tags and keeps updating
//   T3 : back to LIVE=0                                  -> tag 6 again
//   T4 : status registers / no errors / data actually written at the DA addresses / clean stop
//
module tb_dma_top;

    // ------------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------------
    localparam integer W           = 64;
    localparam integer H           = 4;
    localparam integer FRAME_PIX   = W * H;            // 256
    localparam integer FRAME_BYTES = FRAME_PIX * 3;    // 768
    localparam integer FRAME_WORDS = FRAME_BYTES / 4;  // 192
    localparam integer TAG_BRAM    = 6;

    localparam [31:0] BRAM_BASE = 32'h8000_0000;
    localparam [31:0] DA0 = 32'h1000_0000;             // Deliberately non-contiguous addresses
    localparam [31:0] DA1 = 32'h1100_4000;
    localparam [31:0] DA2 = 32'h1230_8000;

    // Register addresses
    localparam [6:0] R_MM2S_CR = 7'h00, R_MM2S_SR = 7'h04, R_SA = 7'h18, R_RERR = 7'h1C,
                     R_BTT = 7'h28, R_BCFG = 7'h30, R_NBUF = 7'h38,
                     R_S2MM_CR = 7'h40, R_S2MM_SR = 7'h44,
                     R_DA0 = 7'h48, R_DA1 = 7'h4C, R_DA2 = 7'h50, R_START = 7'h54, R_WERR = 7'h58;

    localparam [31:0] CR_CYCLIC = 32'h10, CR_LIVE = 32'h20, CR_ERR_EN = 32'h4000;

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #5 aclk = ~aclk;

    // ------------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------------
    wire mm2s_irq, s2mm_irq;

    reg  [6:0]  l_awaddr = 0; reg l_awvalid = 0; wire l_awready;
    reg  [31:0] l_wdata  = 0; reg l_wvalid  = 0; wire l_wready;
    wire [1:0]  l_bresp;      wire l_bvalid;     reg  l_bready = 0;
    reg  [6:0]  l_araddr = 0; reg l_arvalid = 0; wire l_arready;
    wire [31:0] l_rdata;      wire [1:0] l_rresp; wire l_rvalid; reg l_rready = 0;

    reg  [31:0] c_tdata = 0;  reg c_tvalid = 0;  wire c_tready;
    reg         c_tlast = 0;  reg [15:0] c_tuser = 0;

    wire [3:0]  w_awid;  wire [31:0] w_awaddr; wire [3:0] w_awlen; wire [2:0] w_awsize;
    wire [1:0]  w_awburst; wire [1:0] w_awlock; wire [3:0] w_awcache; wire [2:0] w_awprot;
    wire        w_awvalid; wire w_awready;
    wire [3:0]  w_wid;   wire [31:0] w_wdata;  wire [3:0] w_wstrb;
    wire        w_wlast, w_wvalid; wire w_wready;
    wire [3:0]  w_bid;   wire [1:0] w_bresp;   wire w_bvalid; wire w_bready;

    wire [4:0]  r_arid;  wire [31:0] r_araddr; wire [7:0] r_arlen; wire [2:0] r_arsize;
    wire [1:0]  r_arburst; wire r_arlock; wire [3:0] r_arcache; wire [2:0] r_arprot; wire [3:0] r_arqos;
    wire        r_arvalid; wire r_arready;
    reg  [4:0]  r_rid = 0; reg [31:0] r_rdata = 0; wire [1:0] r_rresp; reg r_rlast = 0; reg r_rvalid = 0;
    wire        r_rready;

    wire [23:0] v_tdata; wire [2:0] v_tkeep; wire v_tuser, v_tlast, v_tvalid;
    reg         v_tready = 1'b0;

    dma_top #(
        .PIXELS_PER_LINE (W),
        .FRAME_HEIGHT    (H)
    ) dut (
        .aclk (aclk), .aresetn (aresetn),
        .mm2s_irq (mm2s_irq), .s2mm_irq (s2mm_irq),

        .s_axi_lite_awaddr (l_awaddr), .s_axi_lite_awprot (3'd0),
        .s_axi_lite_awvalid(l_awvalid), .s_axi_lite_awready(l_awready),
        .s_axi_lite_wdata  (l_wdata),  .s_axi_lite_wstrb  (4'hF),
        .s_axi_lite_wvalid (l_wvalid), .s_axi_lite_wready (l_wready),
        .s_axi_lite_bresp  (l_bresp),  .s_axi_lite_bvalid (l_bvalid), .s_axi_lite_bready (l_bready),
        .s_axi_lite_araddr (l_araddr), .s_axi_lite_arprot (3'd0),
        .s_axi_lite_arvalid(l_arvalid), .s_axi_lite_arready(l_arready),
        .s_axi_lite_rdata  (l_rdata),  .s_axi_lite_rresp  (l_rresp),
        .s_axi_lite_rvalid (l_rvalid), .s_axi_lite_rready (l_rready),

        .s_axis_s2mm_tdata (c_tdata), .s_axis_s2mm_tvalid (c_tvalid), .s_axis_s2mm_tready (c_tready),
        .s_axis_s2mm_tlast (c_tlast), .s_axis_s2mm_tkeep (4'hF),      .s_axis_s2mm_tuser (c_tuser),

        .m_axi_s2mm_awid (w_awid), .m_axi_s2mm_awaddr (w_awaddr), .m_axi_s2mm_awlen (w_awlen),
        .m_axi_s2mm_awsize (w_awsize), .m_axi_s2mm_awburst (w_awburst), .m_axi_s2mm_awlock (w_awlock),
        .m_axi_s2mm_awcache (w_awcache), .m_axi_s2mm_awprot (w_awprot),
        .m_axi_s2mm_awvalid (w_awvalid), .m_axi_s2mm_awready (w_awready),
        .m_axi_s2mm_wid (w_wid), .m_axi_s2mm_wdata (w_wdata), .m_axi_s2mm_wstrb (w_wstrb),
        .m_axi_s2mm_wlast (w_wlast), .m_axi_s2mm_wvalid (w_wvalid), .m_axi_s2mm_wready (w_wready),
        .m_axi_s2mm_bid (w_bid), .m_axi_s2mm_bresp (w_bresp),
        .m_axi_s2mm_bvalid (w_bvalid), .m_axi_s2mm_bready (w_bready),

        .m_axi_mm2s_arid (r_arid), .m_axi_mm2s_araddr (r_araddr), .m_axi_mm2s_arlen (r_arlen),
        .m_axi_mm2s_arsize (r_arsize), .m_axi_mm2s_arburst (r_arburst), .m_axi_mm2s_arlock (r_arlock),
        .m_axi_mm2s_arcache (r_arcache), .m_axi_mm2s_arprot (r_arprot), .m_axi_mm2s_arqos (r_arqos),
        .m_axi_mm2s_arvalid (r_arvalid), .m_axi_mm2s_arready (r_arready),
        .m_axi_mm2s_rid (r_rid), .m_axi_mm2s_rdata (r_rdata), .m_axi_mm2s_rresp (r_rresp),
        .m_axi_mm2s_rlast (r_rlast), .m_axi_mm2s_rvalid (r_rvalid), .m_axi_mm2s_rready (r_rready),

        .m_axis_video_tdata (v_tdata), .m_axis_video_tkeep (v_tkeep),
        .m_axis_video_tuser (v_tuser), .m_axis_video_tlast (v_tlast),
        .m_axis_video_tvalid(v_tvalid), .m_axis_video_tready(v_tready)
    );

    // ------------------------------------------------------------------
    // Data rule
    // ------------------------------------------------------------------
    function [7:0] pat(input integer o, input integer tag);
        pat = (o * 7 + tag * 40);
    endfunction

    // ------------------------------------------------------------------
    // Memory (DDR : stores values written by S2MM / BRAM window : loading-screen pattern)
    // ------------------------------------------------------------------
    logic [7:0] ddr [logic [31:0]];     // Sparse memory that stores only written addresses

    function [7:0] mem_byte(input [31:0] a);
        if (a >= BRAM_BASE)       mem_byte = pat(a - BRAM_BASE, TAG_BRAM);
        else if (ddr.exists(a))   mem_byte = ddr[a];
        else                      mem_byte = 8'hEE;   // Unwritten address (checker reports an error if it is read)
    endfunction

    function [31:0] mem_word(input [31:0] a);
        mem_word = {mem_byte(a + 3), mem_byte(a + 2), mem_byte(a + 1), mem_byte(a)};
    endfunction

    // ---------------- AXI3 write slave (S2MM) ----------------
    reg        aw_have = 1'b0;
    reg [31:0] aw_addr_q = 0;
    reg [7:0]  w_beat = 0;
    reg        b_valid_r = 1'b0;

    assign w_awready = !aw_have && !b_valid_r;
    assign w_wready  = aw_have;
    assign w_bvalid  = b_valid_r;
    assign w_bresp   = 2'b00;
    assign w_bid     = 4'd0;

    always @(posedge aclk) begin
        if (!aresetn) begin
            aw_have <= 1'b0; w_beat <= 0; b_valid_r <= 1'b0;
        end else begin
            if (w_awvalid && w_awready) begin
                aw_have   <= 1'b1;
                aw_addr_q <= w_awaddr;
                w_beat    <= 0;
            end
            if (w_wvalid && w_wready) begin
                ddr[aw_addr_q + w_beat*4 + 0] = w_wdata[7:0];
                ddr[aw_addr_q + w_beat*4 + 1] = w_wdata[15:8];
                ddr[aw_addr_q + w_beat*4 + 2] = w_wdata[23:16];
                ddr[aw_addr_q + w_beat*4 + 3] = w_wdata[31:24];
                w_beat <= w_beat + 1'b1;
                if (w_wlast) begin
                    aw_have   <= 1'b0;
                    b_valid_r <= 1'b1;
                end
            end
            if (b_valid_r && w_bready) b_valid_r <= 1'b0;
        end
    end

    // ---------------- AXI4 read slave (MM2S) ----------------
    reg [31:0] q_addr [0:7];
    reg [7:0]  q_len  [0:7];
    reg [4:0]  q_id   [0:7];
    reg [2:0]  q_wp = 0, q_rp = 0;
    reg [3:0]  q_cnt = 0;
    reg [7:0]  r_beat = 0;

    assign r_arready = (q_cnt < 8);
    assign r_rresp   = 2'b00;

    always @(posedge aclk) begin : rd_slave
        integer push, pop;
        if (!aresetn) begin
            q_wp <= 0; q_rp <= 0; q_cnt <= 0; r_beat <= 0; r_rvalid <= 1'b0;
        end else begin
            push = (r_arvalid && r_arready);
            pop  = 0;
            if (push) begin
                q_addr[q_wp] <= r_araddr;
                q_len[q_wp]  <= r_arlen;
                q_id[q_wp]   <= r_arid;
                q_wp         <= q_wp + 1'b1;
            end
            // Prepare the next beat (when there is no current beat or it was just handed off)
            if (!r_rvalid || r_rready) begin
                if (q_cnt != 0 && ($urandom % 5) != 0) begin
                    r_rvalid <= 1'b1;
                    r_rdata  <= mem_word(q_addr[q_rp] + {r_beat, 2'b00});
                    r_rid    <= q_id[q_rp];
                    r_rlast  <= (r_beat == q_len[q_rp]);
                    if (r_beat == q_len[q_rp]) begin
                        r_beat <= 0;
                        q_rp   <= q_rp + 1'b1;
                        pop    = 1;
                    end else begin
                        r_beat <= r_beat + 1'b1;
                    end
                end else begin
                    r_rvalid <= 1'b0;
                end
            end
            q_cnt <= q_cnt + push - pop;
        end
    end

    // ------------------------------------------------------------------
    // Camera stream generator
    // ------------------------------------------------------------------
    reg     cam_en        = 1'b0;
    integer cam_frames    = 0;       // Number of frames sent

    task cam_word(input [31:0] d, input sof, input eof);
        begin
            while (($urandom % 2) == 0) @(posedge aclk);   // Random gaps (camera slower than video output)
            #1;
            c_tdata  = d;
            c_tuser  = {15'd0, sof};
            c_tlast  = eof;
            c_tvalid = 1'b1;
            do @(posedge aclk); while (!c_tready);
            #1;
            c_tvalid = 1'b0;
            c_tuser  = 16'd0;
            c_tlast  = 1'b0;
        end
    endtask

    initial begin : camera
        integer wi, tag;
        wait (cam_en);
        forever begin
            tag = cam_frames % 6;
            for (wi = 0; wi < FRAME_WORDS; wi = wi + 1)
                cam_word({pat(wi*4+3, tag), pat(wi*4+2, tag), pat(wi*4+1, tag), pat(wi*4, tag)},
                         (wi == 0), (wi == FRAME_WORDS - 1));
            cam_frames = cam_frames + 1;
            repeat (200) @(posedge aclk);                   // Blanking between frames
        end
    end

    // ------------------------------------------------------------------
    // Video output checker
    // ------------------------------------------------------------------
    integer pix_cnt   = 0;
    integer frame_cnt = 0;
    integer frame_tag = -1;
    integer last_tag  = -1;
    integer err_cnt   = 0;
    integer live_tag_changes = 0;
    integer prev_live_tag    = -1;

    always @(posedge aclk)
        v_tready <= aresetn && (($urandom % 4) != 0);

    function [23:0] exp_pixel(input integer tag, input integer p);
        exp_pixel = {pat(p*3 + 2, tag), pat(p*3 + 1, tag), pat(p*3, tag)};
    endfunction

    always @(posedge aclk) begin
        if (aresetn && v_tvalid && v_tready) begin
            if (pix_cnt == 0) frame_tag = v_tdata[7:0] / 40;

            if (v_tdata !== exp_pixel(frame_tag, pix_cnt)) begin
                err_cnt = err_cnt + 1;
                if (err_cnt <= 10)
                    $display("[%0t] ERROR pixel: frame %0d pix %0d got %h exp %h (tag %0d)",
                             $time, frame_cnt, pix_cnt, v_tdata, exp_pixel(frame_tag, pix_cnt), frame_tag);
            end
            if (v_tuser !== (pix_cnt == 0)) begin
                err_cnt = err_cnt + 1;
                $display("[%0t] ERROR tuser at pix %0d", $time, pix_cnt);
            end
            if (v_tlast !== ((pix_cnt % W) == W - 1)) begin
                err_cnt = err_cnt + 1;
                $display("[%0t] ERROR tlast at pix %0d", $time, pix_cnt);
            end

            if (pix_cnt == FRAME_PIX - 1) begin
                if (frame_tag == TAG_BRAM)
                    $display("[%0t] frame %0d : BRAM loading image", $time, frame_cnt);
                else
                    $display("[%0t] frame %0d : camera frame (tag %0d)", $time, frame_cnt, frame_tag);
                if (frame_tag != TAG_BRAM) begin
                    if (prev_live_tag != -1 && frame_tag != prev_live_tag)
                        live_tag_changes = live_tag_changes + 1;
                    prev_live_tag = frame_tag;
                end
                last_tag  = frame_tag;
                frame_cnt = frame_cnt + 1;
                pix_cnt   = 0;
            end else begin
                pix_cnt = pix_cnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // AXI-Lite master tasks
    // ------------------------------------------------------------------
    task axil_write(input [6:0] a, input [31:0] d);
        begin
            @(posedge aclk); #1;
            l_awaddr = a; l_awvalid = 1'b1;
            l_wdata  = d; l_wvalid  = 1'b1;
            l_bready = 1'b1;
            do @(posedge aclk); while (!(l_awready && l_wready));
            #1; l_awvalid = 1'b0; l_wvalid = 1'b0;
            while (!l_bvalid) @(posedge aclk);
            @(posedge aclk); #1; l_bready = 1'b0;
        end
    endtask

    task axil_read(input [6:0] a, output [31:0] d);
        begin
            @(posedge aclk); #1;
            l_araddr = a; l_arvalid = 1'b1;
            do @(posedge aclk); while (!l_arready);
            #1; l_arvalid = 1'b0; l_rready = 1'b1;
            do @(posedge aclk); while (!l_rvalid);
            d = l_rdata;
            #1; l_rready = 1'b0;
        end
    endtask

    task wait_frames(input integer n);
        integer target;
        begin
            target = frame_cnt + n;
            wait (frame_cnt >= target);
        end
    endtask

    task check(input cond, input [8*56-1:0] msg);
        begin
            if (cond) $display("  [PASS] %0s", msg);
            else begin
                $display("  [FAIL] %0s", msg);
                err_cnt = err_cnt + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Scenario
    // ------------------------------------------------------------------
    reg [31:0] rd;
    integer    i;

    initial begin
        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
        repeat (5) @(posedge aclk);

        // ================= T0 : start S2MM =================
        $display("\n===== T0 : S2MM start (camera -> DDR) =====");
        axil_write(R_DA0, DA0);
        axil_write(R_DA1, DA1);
        axil_write(R_DA2, DA2);
        axil_write(R_S2MM_CR, CR_ERR_EN);
        axil_write(R_START, 32'd1);
        cam_en = 1'b1;
        axil_read(R_DA1, rd);
        check(rd == DA1,                "T0 DA1 readback");

        // ================= T1 : MM2S loading screen =================
        $display("\n===== T1 : MM2S park on BRAM (loading image) =====");
        axil_write(R_NBUF, 32'd3);
        axil_write(R_SA,   BRAM_BASE);
        axil_write(R_MM2S_CR, CR_CYCLIC | CR_ERR_EN);
        axil_write(R_BTT,  FRAME_BYTES);                 // MM2S start
        wait_frames(3);
        check(last_tag == TAG_BRAM,     "T1 loading image repeats");

        // Wait until S2MM finishes writing the first frame (SR[12] IOC_Irq)
        for (i = 0; i < 20000; i = i + 1) begin
            axil_read(R_S2MM_SR, rd);
            if (rd[12]) i = 20000;
        end
        check(rd[12] == 1'b1,           "T1 S2MM finished first frame");

        // ================= T2 : switch to live =================
        $display("\n===== T2 : LIVE (camera frames from DDR) =====");
        axil_write(R_MM2S_CR, CR_CYCLIC | CR_LIVE | CR_ERR_EN);
        wait_frames(4);
        check(last_tag >= 0 && last_tag <= 5, "T2 output switched to camera");
        wait_frames(20);
        check(live_tag_changes >= 2,    "T2 live frames keep updating");

        // ================= T3 : back to loading screen =================
        $display("\n===== T3 : back to park (BRAM) =====");
        axil_write(R_MM2S_CR, CR_CYCLIC | CR_ERR_EN);
        wait_frames(4);
        check(last_tag == TAG_BRAM,     "T3 back to loading image");

        // ================= T4 : check status / stop =================
        $display("\n===== T4 : status & stop =====");
        axil_read(R_S2MM_SR, rd);
        check(rd[0] == 1'b1,            "T4 S2MM busy (running)");
        check(rd[4] == 1'b0,            "T4 S2MM no write error");
        check(rd[10:8] <= 3'd2,         "T4 S2MM newest idx in 0..2");
        axil_read(R_MM2S_SR, rd);
        check(rd[4] == 1'b0,            "T4 MM2S no read error");
        check(ddr.exists(DA0) && ddr.exists(DA1) && ddr.exists(DA2),
                                        "T4 S2MM wrote all three buffers");

        axil_write(R_MM2S_CR, CR_ERR_EN);                // Clear CYCLIC -> stop
        for (i = 0; i < 5000; i = i + 1) begin
            axil_read(R_MM2S_SR, rd);
            if (rd[1]) i = 5000;
        end
        check(rd[1] == 1'b1,            "T4 MM2S graceful stop -> idle");
        repeat (400) @(posedge aclk);
        check(pix_cnt == 0,             "T4 output ended on frame boundary");
        check(mm2s_irq == 1'b0 && s2mm_irq == 1'b0, "T4 no error interrupts");

        // ================= Results =================
        $display("\n==========================================");
        $display("  camera frames sent : %0d, video frames out : %0d", cam_frames, frame_cnt);
        if (err_cnt == 0) $display("  ALL TESTS PASSED");
        else              $display("  FAILED : %0d error(s)", err_cnt);
        $display("==========================================\n");
        $finish;
    end

    // Watchdog
    initial begin
        #20_000_000;
        $display("TIMEOUT (video frames=%0d, camera frames=%0d)", frame_cnt, cam_frames);
        $finish;
    end

endmodule
