`timescale 1ns / 1ps

module Timer_top (
    input  logic        PCLK,
    input  logic        PRESETn,

    // ===== APB signals connected to the Bridge =====
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [31:0] PADDR,
    input  logic [15:0] PWDATA,
    input  logic [1:0]  PSTRB,
    input  logic [2:0]  PPROT,
    output logic [15:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    output logic        o_irq
);

    logic        w_cnt_en;
    logic [31:0] w_psc;
    logic [31:0] w_arr;
    logic        w_cnt_valid;
    logic [31:0] w_i_cnt;
    logic [31:0] w_o_cnt;
    logic        w_done;

    APB_to_Timer U_BRIDGE (
        .PCLK(PCLK),
        .PRESETn(PRESETn),
        .PSEL(PSEL),
        .PENABLE(PENABLE),
        .PWRITE(PWRITE),
        .PADDR(PADDR),
        .PWDATA(PWDATA),
        .PSTRB(PSTRB),
        .PPROT(PPROT),
        .PRDATA(PRDATA),
        .PREADY(PREADY),
        .PSLVERR(PSLVERR),

        .o_cnt_en   (w_cnt_en),
        .o_psc      (w_psc),
        .o_arr      (w_arr),
        .o_cnt_valid(w_cnt_valid),
        .o_i_cnt    (w_i_cnt),

        .i_done(w_done),

        .o_irq(o_irq)
    );

    timer U_TIMER (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .cnt_en   (w_cnt_en),
        .psc      (w_psc),
        .arr      (w_arr),
        .cnt_valid(w_cnt_valid),   // Bridge always ties this to 1'b0
        .i_cnt    (w_i_cnt),       // Bridge always ties this to 32'h0
        .o_cnt    (w_o_cnt),       // Received but unused
        .o_done   (w_done)
    );

endmodule