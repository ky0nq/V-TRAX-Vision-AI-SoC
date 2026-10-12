`timescale 1ns / 1ps

module APB_to_UART (
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

    // ===== Signals going out to the UART =====
    output logic [7:0]  o_tx_data,  
    output logic        o_tx_valid,
    input  logic        i_tx_ready, 

    input  logic        i_rx_valid,
    input  logic [7:0]  i_rx_data, 

    // ===== Interrupt output =====
    output logic        o_irq
);

    logic [7:0]  rx_data_r;   // Last received rx data
    logic [7:0]  tx_data_r;   // Last written tx data
    logic        irq_en_r;    // Interrupt enable
	logic       irq_pending_r;

    logic w_busy;
    assign w_busy = ~i_tx_ready;
    logic strb_lo;
    assign strb_lo = PSTRB[0];
	assign o_irq = irq_pending_r & irq_en_r;

    always_ff @(posedge PCLK, negedge PRESETn) begin
        if (!PRESETn) begin
            PREADY     <= 1'b0;
            PSLVERR    <= 1'b0;
            PRDATA     <= 16'h0;
            o_tx_valid <= 1'b0;
            o_tx_data  <= 8'h0;
            rx_data_r  <= 8'h0;
            tx_data_r  <= 8'h0;
            irq_en_r   <= 1'b0;
			irq_pending_r <= 1'b0;
        end else begin
            o_tx_valid <= 1'b0; 
			irq_pending_r <= irq_pending_r | i_rx_valid;
			if (i_rx_valid) rx_data_r <= i_rx_data;
            // ---- Reflect receive signals from the UART core ----
            if (PSEL && PENABLE) begin
                PREADY  <= 1'b1;
                PSLVERR <= 1'b0;
                // =========== Write Access ===========
                if (PWRITE) begin
                    case (PADDR[3:0])
                        4'd2 : begin                              // TX_DATA (offset 2)
                            if (strb_lo) begin
                                tx_data_r <= PWDATA[8:1];
                                o_tx_data <= PWDATA[8:1];
                                if (PWDATA[0] && i_tx_ready) begin // Only when start bit && idle
                                    o_tx_valid <= 1'b1;
                                end
                            end
                        end
                        4'd6 : begin                              // IRQ_EN (offset 6)
                            if (strb_lo) irq_en_r <= PWDATA[0];
                        end
                        default : PSLVERR <= 1'b1;
                    endcase
                // =========== Read Access ===========
                end else begin
                    case (PADDR[3:0])
						4'd0 : begin
						   	PRDATA <= {7'h0, rx_data_r, irq_pending_r};
							if (!PREADY) irq_pending_r <= i_rx_valid;
						end
                        4'd2 : PRDATA <= {7'h0, tx_data_r, 1'b0};  // TX_DATA (offset 2)
                        4'd4 : PRDATA <= {15'h0, w_busy};          // STATUS (offset 4)
                        4'd6 : PRDATA <= {15'h0, irq_en_r};        // IRQ_EN (offset 6)
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
