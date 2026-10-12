`timescale 1ns / 1ps

module UART_top #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
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
    output logic        o_irq,

    // ===== Physical pins (connected to ESP32) =====
    output logic         tx,
    input  logic         rx
);

    logic [7:0] w_tx_data;
    logic       w_tx_valid;
    logic       w_tx_ready;
    logic       w_rx_valid;
    logic [7:0] w_rx_data;

    APB_to_UART U_BRIDGE (
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

        .o_tx_data (w_tx_data),
        .o_tx_valid(w_tx_valid),
        .i_tx_ready(w_tx_ready),
        .i_rx_valid(w_rx_valid),
        .i_rx_data (w_rx_data),

        .o_irq(o_irq)
    );

    uart #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) U_UART (
        .clk     (PCLK),
        .rst_n   (PRESETn),
        .tx_data (w_tx_data),
        .tx_valid(w_tx_valid),
        .tx_ready(w_tx_ready),
        .tx      (tx),
        .rx      (rx),
        .rx_data (w_rx_data),
        .rx_valid(w_rx_valid)
    );

endmodule