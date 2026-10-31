// ============================================================
// cnn_img_if : Image RAM read port (read only, no handshake)
//   When the DUT issues an address, data must be present on the next clk (synchronous RAM, 1 clk latency)
//   4096 words x 24bit : word = y*64 + x, [7:0] ch0  [15:8] ch1  [23:16] ch2
// ============================================================
`timescale 1ns / 1ps

interface cnn_img_if (
	input logic clk,
	input logic rst_n
);

	localparam int AW = 12;
	localparam int DW = 24;

	logic [AW-1:0] rd_addr;    // DUT -> RAM
	logic [DW-1:0] rdata;      // RAM -> DUT (clk after the address)

	// responder : samples the address at the edge (#1step pre-edge value) and drives data just after that same edge
	//   -> the DUT sees it on the next edge = same timing as a synchronous RAM
	clocking rsp_cb @(posedge clk);
		default input #1step output #1;
		input  rd_addr;
		output rdata;
	endclocking

	clocking mon_cb @(posedge clk);
		default input #1step;
		input rd_addr, rdata;
	endclocking

endinterface
