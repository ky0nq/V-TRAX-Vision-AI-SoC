// ============================================================
// cnn_wgt_if : shared Weight + Bias(param) RAM read port (read only, no handshake)
//   When the DUT issues an address, data must be present on the next clk (synchronous RAM, 1 clk latency)
//   45293 words x 32bit : 0 .. 45249 weight (24bit used), 45250 .. 45292 bias (signed INT32)
// ============================================================
`timescale 1ns / 1ps

interface cnn_wgt_if (
	input logic clk,
	input logic rst_n
);

	localparam int AW = 16;
	localparam int DW = 32;

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
