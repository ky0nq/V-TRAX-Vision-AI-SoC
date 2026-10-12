`timescale 1ns / 1ps

module GPIO_top (
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
    output logic [7:0]  o_irq,

    // ===== Physical pins =====
    inout  wire  [15:0] io_port
);

    logic [15:0] w_cr;
    logic [15:0] w_aodr;
    logic [15:0] w_idr;

    APB_to_GPIO U_BRIDGE (
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

        .o_cr  (w_cr),
        .o_aodr(w_aodr),
        .i_idr (w_idr),

        .o_irq(o_irq)
    );
	//genvar i;
	//generate
    //    for (i = 0; i < 16; i = i + 1) begin : GPIO_PIN
    //        assign io_port[i] = w_cr[i] ? w_aodr[i] : 1'bz;
    //        assign w_idr[i]     = io_port[i];
    //    end
    //endgenerate
	genvar i;
	generate
	    for (i = 0; i < 16; i = i + 1) begin : GPIO_PIN
	        IOBUF u_iobuf (
	            .IO(io_port[i]),  // external pin
	            .I (w_aodr[i]),   // output data
	            .O (w_idr[i]),    // input data
	            .T (~w_cr[i])     // CR=0: input, CR=1: output
	        );
	    end
	endgenerate
endmodule