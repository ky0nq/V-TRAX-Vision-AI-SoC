
`timescale 1ns / 1ps

module APB_to_GPIO (
    input  wire        PCLK,
    input  wire        PRESETn,

    // ===== APB signals connected to the Bridge =====
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [31:0] PADDR,
    input  wire [15:0] PWDATA,
    input  wire [1:0]  PSTRB,
    input  wire [2:0]  PPROT,

    output reg  [15:0] PRDATA,
    output reg         PREADY,
    output reg         PSLVERR,

    // ===== Signals going out to GPIO =====
    output wire [15:0] o_cr,
    output wire [15:0] o_aodr,

    // ===== Signals coming in from GPIO =====
    input  wire [15:0] i_idr,

    // ===== Interrupt output =====
    output wire [7:0]  o_irq
);

    reg [15:0] cr_r;
    reg [15:0] aodr_r;

    // Two-stage synchronization of asynchronous GPIO inputs
    reg [15:0] idr_meta_r;
    reg [15:0] idr_sync_r;
    reg [15:0] idr_prev_r; // prev holds the synchronized idr value from the previous clock
    reg [7:0]  irq_r;

    wire strb_lo;
    wire strb_hi;
    wire [7:0] w_negedge;
    wire [7:0] w_irq_clear;

    assign o_cr     = cr_r;
    assign o_aodr   = aodr_r;
    assign o_irq    = irq_r;
    assign strb_lo  = PSTRB[0];
    assign strb_hi  = PSTRB[1];

    // 1->0 negedge: synchronized pin is 0 now & was 1 on the previous clock & currently in input mode
    assign w_negedge = ~idr_sync_r[7:0] & idr_prev_r[7:0] & ~cr_r[7:0];

    // W1C: clear only on an APB completed write to ISR (offset 0x06)
    // PSTRB[0] must be 1 to enable writing the low byte containing the IRQ bits
    // the CPU writes 1 to the bits it wants to clear; bits written with 0 keep their value
    assign w_irq_clear =
        (PSEL && PENABLE && PREADY && PWRITE &&
         PADDR[3:0] == 4'd6 && strb_lo)
        ? PWDATA[7:0] : 8'h00;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            idr_meta_r <= 16'h0000;
            idr_sync_r <= 16'h0000;
        end else begin
            idr_meta_r <= i_idr;
            idr_sync_r <= idr_meta_r;
        end
    end

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PREADY     <= 1'b0;
            PSLVERR    <= 1'b0;
            PRDATA     <= 16'h0000;
            cr_r       <= 16'h0000;
            aodr_r     <= 16'h0000;
            idr_prev_r <= 16'h0000;
            irq_r      <= 8'h00;
        end else begin
            idr_prev_r <= idr_sync_r; // store previous synchronized value
            // A new edge takes priority over clearing the same IRQ bit.
            irq_r <= (irq_r & ~w_irq_clear) | w_negedge;

            if (PSEL && PENABLE) begin
                PREADY  <= 1'b1;
                PSLVERR <= 1'b0;
                // =========== Write Access ===========
                if (PWRITE) begin
                    case (PADDR[3:0])
                        4'd0: begin  // CR (offset 0)
                            if (PREADY && strb_lo) cr_r[7:0]  <= PWDATA[7:0];
                            if (PREADY && strb_hi) cr_r[15:8] <= PWDATA[15:8];
                        end
                        4'd4: begin  // OUT (offset 4)
                            if (PREADY && strb_lo) aodr_r[7:0]  <= PWDATA[7:0];
                            if (PREADY && strb_hi) aodr_r[15:8] <= PWDATA[15:8];
                        end
                        4'd6: begin  // ISR (offset 6): W1C handled by w_irq_clear
                        end
                        default: PSLVERR <= 1'b1;
                    endcase
                // =========== Read Access ===========
                end else begin
                    case (PADDR[3:0])
                        4'd0: PRDATA <= cr_r;
                        4'd2: PRDATA <= idr_sync_r; // read synchronized GPIO input
                        4'd4: PRDATA <= aodr_r;
                        4'd6: PRDATA <= {8'h00, irq_r};
                        default: begin
                            PRDATA  <= 16'h0000;
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