`timescale 1ns / 1ps

module APB_to_Timer (
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

    // ===== Signals going out to the Timer =====
    output logic        o_cnt_en,
    output logic [31:0] o_psc,
    output logic [31:0] o_arr,
    output logic        o_cnt_valid,  // Always 1'b0
    output logic [31:0] o_i_cnt,      // Always 32'h0

    // ===== Signals coming in from the Timer =====
    input  logic        i_done,

    // ===== Interrupt output =====
    output logic        o_irq
);

    logic        cnt_en_r;
    logic [15:0] psc_r, arr_r;
    logic        irq_en_r;
	logic        irq_pending_r;

    assign o_cnt_valid = 1'b0;
    assign o_i_cnt     = 32'h0;
    assign o_psc       = {16'h0, psc_r};
    assign o_arr       = {16'h0, arr_r};
    assign o_cnt_en    = cnt_en_r;
	assign o_irq = irq_en_r & irq_pending_r;
    
	logic strb_lo;
    logic strb_hi;
    assign strb_lo = PSTRB[0];
    assign strb_hi = PSTRB[1];

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PREADY     <= 1'b0;
            PSLVERR    <= 1'b0;
            PRDATA     <= 16'h0;
            cnt_en_r   <= 1'b0; 
            psc_r      <= 16'h0;
            arr_r      <= 16'h0;
            irq_en_r   <= 1'b0;
			irq_pending_r <= 1'b0;
        end else begin
			irq_pending_r <= irq_pending_r | i_done;
            if (PSEL && PENABLE) begin
                PREADY  <= 1'b1;
                PSLVERR <= 1'b0;
                // =========== Write Access ===========
                if (PWRITE) begin
                    case (PADDR[3:0])
                        4'd0: begin                                  // CR (offset 0)
                            if (strb_lo) begin
                                cnt_en_r <= PWDATA[0];
                                irq_en_r <= PWDATA[1];
                            end
                        end
                        4'd2: begin                                  // PSC (offset 2)
                            if (strb_lo) psc_r[7:0]  <= PWDATA[7:0];
                            if (strb_hi) psc_r[15:8] <= PWDATA[15:8];
                        end
                        4'd4: begin                                  // ARR (offset 4)
                            if (strb_lo) arr_r[7:0]  <= PWDATA[7:0];
                            if (strb_hi) arr_r[15:8] <= PWDATA[15:8];
                        end
						 4'h6: begin
                            if (strb_lo) begin
                                irq_pending_r <=
                                    (irq_pending_r & ~PWDATA[0]) |
                                    i_done;
                            end
                        end
                        default : PSLVERR <= 1'b1;
                    endcase
                end
                // =========== Read Access ===========
                else begin
                    case (PADDR[3:0])
                        4'd0 : PRDATA <= {14'h0, irq_en_r, cnt_en_r};
                        4'd2 : PRDATA <= psc_r;
                        4'd4 : PRDATA <= arr_r;
                        //4'd6 : PRDATA <= {15'h0, i_done};
						4'h6 : PRDATA <= { 15'h0000, irq_pending_r };
                        default : begin
                            PRDATA  <= 16'h0;
                            PSLVERR <= 1'b1;
                        end
                    endcase
                end
            end else begin
                PREADY  <= 1'b0;
                PSLVERR <= 1'b0;
            end
        end
    end

endmodule
