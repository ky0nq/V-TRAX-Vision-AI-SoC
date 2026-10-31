// ============================================================
// cnn_ctrl_if : top_cnn control pins (start / busy / done / irq / final_result) + debug outputs
//   Not an AXI4-Lite bus. Attaches directly to the top_cnn ports, with no wrapper
//   This interface also owns rst_n : host_agent's driver applies reset like a SoC host
// ============================================================
`timescale 1ns / 1ps

interface cnn_ctrl_if (input logic clk);

	logic       rst_n = 1'b0;      // driven procedurally by the driver (initial value 0)

	// ---- control ----
	logic       start_valid;
	logic       start_ready;
	logic       busy;
	logic       irq_en;
	logic       irq_clear;
	logic [7:0] final_result;
	logic       done_status;
	logic       irq;

	// ---- debug ----
	logic [2:0] layer_idx;
	logic [3:0] cnn_state;

	// driver
	clocking drv_cb @(posedge clk);
		default input #1step output #1;
		output start_valid, irq_en, irq_clear;
		input  start_ready, busy, final_result, done_status, irq, layer_idx, cnn_state;
	endclocking

	// monitor
	clocking mon_cb @(posedge clk);
		default input #1step;
		input start_valid, start_ready, busy, irq_en, irq_clear, final_result, done_status, irq, layer_idx, cnn_state;
	endclocking

endinterface
