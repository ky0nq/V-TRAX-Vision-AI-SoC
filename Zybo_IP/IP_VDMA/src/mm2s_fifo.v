`timescale 1ns / 1ps
//
// Write side (Read Engine) : fifo_wr_en / fifo_wr_data / fifo_full
// Read side (depacketizer) : fifo_rd_en / fifo_rd_data / fifo_empty
//

module mm2s_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH      = 16,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ===== Write side (connected to mm2s_engine) =====
    input  wire                    fifo_wr_en,
    input  wire [DATA_WIDTH-1:0]   fifo_wr_data,
    output wire                    fifo_full,

    // ===== Read side (connected to the mm2s_depacketizer adapter) =====
    input  wire                    fifo_rd_en,
    output wire [DATA_WIDTH-1:0]   fifo_rd_data,
    output wire                    fifo_empty,

    // ===== Status for reference (use if needed for debugging / almost-full detection, etc.) =====
    output wire [ADDR_WIDTH:0]     fifo_count      // 0 ~ DEPTH, current fill count
);

    // ------------------------------------------------------------------
    // Memory array (automatically mapped to distributed RAM or BRAM during synthesis; LUT-RAM if DEPTH is small)
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH-1:0] wr_ptr;
    reg [ADDR_WIDTH-1:0] rd_ptr;
    reg [ADDR_WIDTH:0]   count;   // One bit wider to distinguish 'full' from 'empty'

    assign fifo_full  = (count == DEPTH[ADDR_WIDTH:0]);
    assign fifo_empty = (count == {(ADDR_WIDTH+1){1'b0}});
    assign fifo_count = count;

    wire do_write = fifo_wr_en && !fifo_full;
    wire do_read  = fifo_rd_en && !fifo_empty;

    // ------------------------------------------------------------------
    // Write pointer + memory write
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
        end else if (do_write) begin
            mem[wr_ptr] <= fifo_wr_data;
            wr_ptr      <= wr_ptr + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Read pointer (read data is handled by the combinational read below - fall-through style)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr <= {ADDR_WIDTH{1'b0}};
        end else if (do_read) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end

    assign fifo_rd_data = mem[rd_ptr];

    // ------------------------------------------------------------------
    // Fill counter
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            count <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({do_write, do_read})
                2'b10:   count <= count + 1'b1;   // Write only
                2'b01:   count <= count - 1'b1;   // Read only
                default: count <= count;          // Neither, or both at once (they cancel out)
            endcase
        end
    end

`ifndef SYNTHESIS
    // Simulation safeguard: warn on a write attempt when full or a read attempt when empty
    always @(posedge clk) begin
        if (rst_n && fifo_wr_en && fifo_full)
            $display("[WARN][mm2s_fifo] write attempted while FULL at time %0t", $time);
        if (rst_n && fifo_rd_en && fifo_empty)
            $display("[WARN][mm2s_fifo] read attempted while EMPTY at time %0t", $time);
    end
`endif

endmodule