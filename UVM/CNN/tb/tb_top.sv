// ============================================================
// tb_top : top_cnn UVM testbench top
//   The DUT is top_cnn. The AXI4-Lite wrapper (AXI4_Lite_interconnect_v1_0*) is not included.
//   The TB drives the start / irq pins directly in place of the ARM, and stands in for both RAMs.
//   clk 10 ns.  Reset is applied by host_agent's driver via U_CTRL_VIF.rst_n
//
//   cnn_ctrl_if U_CTRL_VIF : host_agent  <-> control pins
//   cnn_img_if  U_IMG_VIF  : img_agent   <-> Image RAM port
//   cnn_wgt_if  U_WGT_VIF  : wgt_agent   <-> shared Weight + Bias RAM port
//   sva (bind)             : cnn_sva_bind (top_cnn ports + internal modules)
//   act_buf_probe          : input_buf read for layer_scb
// ============================================================
`timescale 1ns / 1ps
`include "cnn_tb_defs.svh"

import uvm_pkg::*;
import cnn_pkg::*;

module tb_top;

	logic clk;

	// clock generate
	initial clk = 1'b0;
	always #5 clk = ~clk;

	// interface instance
	cnn_ctrl_if U_CTRL_VIF (
		.clk (clk)
	);

	cnn_img_if U_IMG_VIF (
		.clk   (clk),
		.rst_n (U_CTRL_VIF.rst_n)
	);

	cnn_wgt_if U_WGT_VIF (
		.clk   (clk),
		.rst_n (U_CTRL_VIF.rst_n)
	);

	// =============================
	// dut
	// =============================
	top_cnn #(
		.IMG_RAM_BASE (32'd0),
		.IMG_WORDS    (13'd4096),
		.L0_QM (CNN_L0_QM), .L0_QS (CNN_L0_QS),
		.L1_QM (CNN_L1_QM), .L1_QS (CNN_L1_QS),
		.L2_QM (CNN_L2_QM), .L2_QS (CNN_L2_QS),
		.L3_QM (CNN_L3_QM), .L3_QS (CNN_L3_QS)
	) dut (
		.clk            (clk),
		.rst_n          (U_CTRL_VIF.rst_n),

		// ---- control pins (driven by the AXI4-Lite wrapper when it is used; here host_agent drives them directly) ----
		.i_start_valid  (U_CTRL_VIF.start_valid),
		.o_start_ready  (U_CTRL_VIF.start_ready),
		.o_busy         (U_CTRL_VIF.busy),
		.i_irq_en       (U_CTRL_VIF.irq_en),
		.i_irq_clear    (U_CTRL_VIF.irq_clear),
		.o_final_result (U_CTRL_VIF.final_result),
		.o_done_status  (U_CTRL_VIF.done_status),
		.o_irq          (U_CTRL_VIF.irq),

		// ---- Image RAM ----
		.o_img_rd_addr  (U_IMG_VIF.rd_addr),
		.i_img_rdata    (U_IMG_VIF.rdata),

		// ---- shared RAM (Weight + Bias) ----
		.o_ram_rd_addr  (U_WGT_VIF.rd_addr),
		.i_rdata        (U_WGT_VIF.rdata),

		// ---- debug ----
		.o_layer_idx    (U_CTRL_VIF.layer_idx),
		.o_cnn_state    (U_CTRL_VIF.cnn_state)
	);

	// =============================
	// SVA (bind) : top_cnn ports (cnn_top_sva) + internal modules, all bound in cnn_sva_bind
	// =============================
	cnn_sva_bind U_SVA_BIND ();

	// =============================
	// act_buf_probe : input_buf white-box read (for layer_scb)
	//   Hierarchical references are kept only in a class inside the module
	//   (an interface containing hierarchical references cannot be used as a virtual interface : IEEE 1800-2017 25.9)
	// =============================
	class cnn_act_buf_probe extends cnn_act_buf_probe_base;
		virtual function logic [23:0] act_buf_read(int unsigned addr);
			return `CNN_ACT_BUF_MEM[addr];
		endfunction
	endclass

	cnn_act_buf_probe act_buf_probe;

	// =============================
	// UVM
	// =============================
	initial begin
		act_buf_probe = new();
		uvm_config_db#(cnn_act_buf_probe_base)::set(null, "*", "act_buf_probe", act_buf_probe);
		uvm_config_db#(virtual cnn_ctrl_if)::set(null, "*", "ctrl_vif", U_CTRL_VIF);
		uvm_config_db#(virtual cnn_img_if)::set(null, "*", "img_vif", U_IMG_VIF);
		uvm_config_db#(virtual cnn_wgt_if)::set(null, "*", "wgt_vif", U_WGT_VIF);
		run_test();
	end

	// =============================
	// waveform (only with +DUMP. One inference takes ~450k clk, so it is off by default)
	// =============================
	initial begin
		if ($test$plusargs("DUMP")) begin
			$fsdbDumpfile("wave.fsdb");
			$fsdbDumpvars(0, tb_top);
			$fsdbDumpMDA();
		end
	end

endmodule
