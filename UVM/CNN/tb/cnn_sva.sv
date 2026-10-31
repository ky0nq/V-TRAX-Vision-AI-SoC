// ============================================================
// cnn_sva : SVA, all attached with bind (the cnn_sva_bind module instantiated in tb_top holds the bind statements)
//   cnn_top_sva   : bound to top_cnn, on its ports
//   *_sva         : bound to internal modules
//   assertion failures are reported via `uvm_error so they are reflected in UVM PASS / FAIL
// ============================================================
`timescale 1ns / 1ps
`include "uvm_macros.svh"

// ------------------------------------------------------------
// top_cnn ports
// ------------------------------------------------------------
module cnn_top_sva (
	input logic        clk,
	input logic        rst_n,
	input logic        start_valid,
	input logic        start_ready,
	input logic        busy,
	input logic        irq_en,
	input logic        irq_clear,
	input logic [7:0]  final_result,
	input logic        done_status,
	input logic        irq,
	input logic [3:0]  cnn_state
);
	import uvm_pkg::*;

	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	// irq = irq_en && done_status (result_buf)
	a_irq_eq : assert property (irq == (irq_en && done_status))
		else `uvm_error("SVA", $sformatf("irq(%0b) != irq_en(%0b) && done_status(%0b)", irq, irq_en, done_status));

	// start_ready only when IDLE and done_status = 0
	a_ready_not_busy : assert property (start_ready |-> (!busy && !done_status))
		else `uvm_error("SVA", "start_ready while busy or done_status");

	// busy from the clk after start fire
	a_start_busy : assert property ((start_valid && start_ready) |=> busy)
		else `uvm_error("SVA", "busy not asserted after start fire");

	// busy == (cnn_state != C_IDLE)
	a_busy_state : assert property (busy == (cnn_state != 4'd0))
		else `uvm_error("SVA", "busy inconsistent with cnn_state");

	// done_status rises only while busy (the edge where the final result is stored)
	a_done_in_busy : assert property ($rose(done_status) |-> busy)
		else `uvm_error("SVA", "done_status rose while not busy");

	// irq_clear -> done_status 0 on the next clk (while idle, so no final store coincides in the same clk)
	a_irq_clear : assert property ((irq_clear && done_status && !busy) |=> !done_status)
		else `uvm_error("SVA", "done_status not cleared by irq_clear");

	// final_result stable while done_status is held
	a_result_stable : assert property ((done_status && !irq_clear) |=> $stable(final_result))
		else `uvm_error("SVA", "final_result changed while done_status held");

	// cnn_state is 0 .. 10
	a_state_range : assert property (cnn_state <= 4'd10)
		else `uvm_error("SVA", $sformatf("illegal cnn_state %0d", cnn_state));

	// done_status held for at least 1 clk, until irq_clear (it does not drop on its own)
	a_done_hold : assert property ((done_status && !irq_clear) |=> done_status)
		else `uvm_error("SVA", "done_status dropped without irq_clear");

	// ---- coverage ----
	c_start      : cover property (start_valid && start_ready);
	c_done_irq   : cover property ($rose(done_status) && irq_en);
	c_done_noirq : cover property ($rose(done_status) && !irq_en);
	c_clear      : cover property (irq_clear && done_status);
endmodule


// ------------------------------------------------------------
// cnn_cntl (top_cnn_cntl.sv)
// ------------------------------------------------------------
module cnn_cntl_sva (
	input logic       clk,
	input logic       rst_n,
	input logic       o_tile_cfg_valid,
	input logic       i_tile_ready,
	input logic       o_wload_start,
	input logic       i_wload_ready,
	input logic       o_busy,
	input logic       o_start_ready,
	input logic [3:0] o_state,
	input logic       o_pg_tile_start,
	input logic       o_fc_tile_start,
	input logic       o_fc_mode,
	input logic       o_layer_cfg_valid,
	input logic       o_tile_valid
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	// Requirement 4 : tile_cfg only when pe_cntl is ready
	a_tcfg_ready     : assert property (o_tile_cfg_valid |-> i_tile_ready)
		else `uvm_error("SVA", "cnn_cntl : o_tile_cfg_valid while !i_tile_ready");
	a_tcfg_pulse     : assert property (o_tile_cfg_valid |=> !o_tile_cfg_valid)
		else `uvm_error("SVA", "cnn_cntl : o_tile_cfg_valid longer than 1 clk");
	// weight load start only in a clk where ready is seen
	a_wload_ready    : assert property (o_wload_start |-> i_wload_ready)
		else `uvm_error("SVA", "cnn_cntl : o_wload_start while !i_wload_ready");
	a_wload_pulse    : assert property (o_wload_start |=> !o_wload_start)
		else `uvm_error("SVA", "cnn_cntl : o_wload_start longer than 1 clk");
	a_busy_state     : assert property (o_busy == (o_state != 4'd0))
		else `uvm_error("SVA", "cnn_cntl : o_busy inconsistent with state");
	a_ready_idle     : assert property (o_start_ready |-> !o_busy)
		else `uvm_error("SVA", "cnn_cntl : o_start_ready while busy");
	a_tile_start_1h  : assert property (!(o_pg_tile_start && o_fc_tile_start))
		else `uvm_error("SVA", "cnn_cntl : pg and fc tile_start together");
	a_pg_conv_only   : assert property (o_pg_tile_start |-> !o_fc_mode)
		else `uvm_error("SVA", "cnn_cntl : o_pg_tile_start in FC mode");
	a_fc_fc_only     : assert property (o_fc_tile_start |-> o_fc_mode)
		else `uvm_error("SVA", "cnn_cntl : o_fc_tile_start in Conv mode");
	a_lcfg_pulse     : assert property (o_layer_cfg_valid |=> !o_layer_cfg_valid)
		else `uvm_error("SVA", "cnn_cntl : o_layer_cfg_valid longer than 1 clk");
	// tile command only after tile_cfg (never in the same clk)
	a_tile_valid_cfg : assert property (o_tile_valid |-> !o_tile_cfg_valid)
		else `uvm_error("SVA", "cnn_cntl : o_tile_valid together with o_tile_cfg_valid");
endmodule


// ------------------------------------------------------------
// pe_cntl (top_cnn_cntl.sv)
// ------------------------------------------------------------
module pe_cntl_sva (
	input logic clk,
	input logic rst_n,
	input logic o_step_en,
	input logic o_feed_valid,
	input logic i_act_valid,
	input logic i_weight_valid,
	input logic o_acc_clear,
	input logic o_chunk_start,
	input logic o_feed_en,
	input logic o_chunk_req,
	input logic i_chunk_loaded,
	input logic o_tile_ready,
	input logic i_tile_valid
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	a_feed_both     : assert property (o_feed_valid |-> (i_act_valid && i_weight_valid))
		else `uvm_error("SVA", "pe_cntl : feed_valid without both act and weight valid");
	a_feed_is_step  : assert property (o_feed_valid |-> o_step_en)
		else `uvm_error("SVA", "pe_cntl : feed_valid without step_en");
	a_clear_no_step : assert property (o_acc_clear |-> !o_step_en)
		else `uvm_error("SVA", "pe_cntl : acc_clear together with step_en");
	a_chunk_feed    : assert property (o_chunk_start |-> o_feed_en)
		else `uvm_error("SVA", "pe_cntl : chunk_start while !feed_en");
	a_chunk_pulse   : assert property (o_chunk_start |=> !o_chunk_start)
		else `uvm_error("SVA", "pe_cntl : chunk_start longer than 1 clk");
	a_loaded_req    : assert property (i_chunk_loaded |-> o_chunk_req)
		else `uvm_error("SVA", "pe_cntl : chunk_loaded without outstanding chunk_req");
	a_req_served    : assert property ($rose(o_chunk_req) |-> ##[1:$] i_chunk_loaded)
		else `uvm_error("SVA", "pe_cntl : chunk_req never served");

	c_tile_fire : cover property (i_tile_valid && o_tile_ready);
	c_chunk_req : cover property ($rose(o_chunk_req));
endmodule


// ------------------------------------------------------------
// post_process (out_path.sv)
// ------------------------------------------------------------
module post_process_sva (
	input logic        clk,
	input logic        rst_n,
	input logic        i_cfg_valid,
	input logic        o_cfg_ready,
	input logic        i_valid,
	input logic        o_ready,
	input logic [2:0]  i_keep,
	input logic        o_valid,
	input logic        i_ready,
	input logic [23:0] o_data,
	input logic [2:0]  o_keep,
	input logic [18:0] o_meta,
	input logic        o_final_valid,
	input logic        i_final_ready,
	input logic [7:0]  o_final_data
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	// Requirement 4 : must always be able to accept cfg when it arrives
	a_cfg_accept   : assert property (i_cfg_valid |-> o_cfg_ready)
		else `uvm_error("SVA", "post_process : i_cfg_valid while !o_cfg_ready (cfg dropped)");
	a_keep_legal   : assert property ((i_valid && o_ready) |-> (i_keep inside {3'b001, 3'b011, 3'b111}))
		else `uvm_error("SVA", "post_process : illegal keep accepted");
	// valid/ready : data held while waiting
	a_out_stable   : assert property ((o_valid && !i_ready) |=> (o_valid && $stable(o_data) && $stable(o_keep) && $stable(o_meta)))
		else `uvm_error("SVA", "post_process : output changed while stalled");
	a_final_stable : assert property ((o_final_valid && !i_final_ready) |=> (o_final_valid && $stable(o_final_data)))
		else `uvm_error("SVA", "post_process : final output changed while stalled");
	a_no_both      : assert property (!(o_valid && o_final_valid))
		else `uvm_error("SVA", "post_process : normal and final output valid together");
endmodule


// ------------------------------------------------------------
// output_fifo (out_path.sv)
// ------------------------------------------------------------
module output_fifo_sva (
	input logic        clk,
	input logic        rst_n,
	input logic        i_cfg_valid,
	input logic        o_cfg_ready,
	input logic        cfg_mask_valid,
	input logic        o_valid,
	input logic        i_ready,
	input logic [95:0] o_data,
	input logic [8:0]  i_result_valid,
	input logic        tile_active
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	a_cfg_accept : assert property (i_cfg_valid |-> o_cfg_ready)
		else `uvm_error("SVA", "output_fifo : i_cfg_valid while tile still active (cfg dropped)");
	a_cfg_mask   : assert property (i_cfg_valid |-> cfg_mask_valid)
		else `uvm_error("SVA", "output_fifo : cfg with illegal row/col mask");
	a_out_stable : assert property ((o_valid && !i_ready) |=> (o_valid && $stable(o_data)))
		else `uvm_error("SVA", "output_fifo : output changed while stalled");
	a_res_active : assert property ((|i_result_valid) |-> tile_active)
		else `uvm_error("SVA", "output_fifo : PE result while no tile active (result lost)");
endmodule


// ------------------------------------------------------------
// pooling_unit (out_path.sv)
// ------------------------------------------------------------
module pooling_unit_sva (
	input logic        clk,
	input logic        rst_n,
	input logic        i_cfg_valid,
	input logic        i_valid,
	input logic        o_ready,
	input logic [2:0]  i_keep,
	input logic        o_valid,
	input logic        i_ready,
	input logic [23:0] o_data
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	a_cfg_no_pending : assert property (i_cfg_valid |-> !o_valid)
		else `uvm_error("SVA", "pooling_unit : layer cfg while output pending (output dropped)");
	a_out_stable     : assert property ((o_valid && !i_ready) |=> (o_valid && $stable(o_data)))
		else `uvm_error("SVA", "pooling_unit : output changed while stalled");
	a_keep_legal     : assert property ((i_valid && o_ready) |-> (i_keep inside {3'b001, 3'b011, 3'b111}))
		else `uvm_error("SVA", "pooling_unit : illegal keep accepted");
endmodule


// ------------------------------------------------------------
// result_buf (out_path.sv)
// ------------------------------------------------------------
module result_buf_sva (
	input logic clk,
	input logic rst_n,
	input logic o_wr_en,
	input logic i_write_grant,
	input logic i_cfg_valid,
	input logic i_valid,
	input logic i_final_valid,
	input logic o_final_ready
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	a_wr_grant  : assert property (o_wr_en |-> i_write_grant)
		else `uvm_error("SVA", "result_buf : write without write_grant");
	a_cfg_quiet : assert property (i_cfg_valid |-> !(i_valid || i_final_valid))
		else `uvm_error("SVA", "result_buf : layer cfg while input pending");
	c_final     : cover property (i_final_valid && o_final_ready);
endmodule


// ------------------------------------------------------------
// wgt_ld_unit / wgt_patch_gen (wgt_path.sv)
// ------------------------------------------------------------
module wgt_ld_unit_sva (
	input logic clk,
	input logic rst_n,
	input logic i_ld_start,
	input logic o_ld_ready
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_start_ready : assert property (i_ld_start |-> o_ld_ready)
		else `uvm_error("SVA", "wgt_ld_unit : ld_start while !ld_ready (chunk load dropped)");
endmodule

module wgt_patch_gen_sva (
	input logic clk,
	input logic rst_n,
	input logic i_chunk_start,
	input logic chunk_active
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_start_idle : assert property (i_chunk_start |-> !chunk_active)
		else `uvm_error("SVA", "wgt_patch_gen : chunk_start while previous chunk active (start dropped)");
endmodule


// ------------------------------------------------------------
// wgt_path (wgt_path.sv) : half conflict in the wgt_buf double buffer
//   wgt_buf is 512 words = 2 halves x 256, and address [8] selects the half.
//   While wgt_ld_unit writes the next chunk into one half, wgt_patch_gen must read the other half.
//   ram_rsp always has a fixed 1 clk latency, so the load/read overlap pattern is the same every time.
//   So result comparison alone (layer checker / scoreboard) can miss an overwrite; SVA checks it directly.
//   Weight values are the RAM contents as-is, so no need to compare values via probe. The risky part is control.
//   If c_overlap never hits, load and read never overlapped, so a PASS of a_no_overwrite is meaningless.
//   The number of overlapping clks is printed at the end.
// ------------------------------------------------------------
module wgt_path_sva (
	input logic       clk,
	input logic       rst_n,
	input logic       buf_we,       // wgt_ld_unit.o_buf_we
	input logic [8:0] buf_waddr,    // wgt_ld_unit.o_buf_waddr = {half, idx}
	input logic       rd_active,    // wgt_patch_gen.chunk_active
	input logic       rd_half       // wgt_patch_gen.rd_half_r (half currently being read)
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);

	int unsigned n_overlap  = 0;    // number of clks where load and read overlapped
	int unsigned n_wr_half0 = 0;    // number of clks writing half 0
	int unsigned n_wr_half1 = 0;    // number of clks writing half 1

	// Key : never write to the half the PE is currently reading
	a_no_overwrite : assert property ((buf_we && rd_active) |-> (buf_waddr[8] != rd_half))
		else `uvm_error("SVA", $sformatf("wgt_buf : writing half %0d (waddr=%0d) while wgt_patch_gen reads it",
			buf_waddr[8], buf_waddr));

	// whether the double buffer actually operated with overlap, and whether both halves were written
	c_overlap  : cover property (buf_we && rd_active)     n_overlap++;
	c_half0_wr : cover property (buf_we && !buf_waddr[8]) n_wr_half0++;
	c_half1_wr : cover property (buf_we &&  buf_waddr[8]) n_wr_half1++;

	final begin
		$display("[wgt_path_sva] %m : overlap=%0d clk, write half0=%0d clk, half1=%0d clk%s",
			n_overlap, n_wr_half0, n_wr_half1,
			(n_overlap == 0) ? "  (WARNING : load never overlapped read, a_no_overwrite not exercised)" : "");
	end
endmodule


// ------------------------------------------------------------
// act_patch_gen / fc_gen / act_ld_unit (act_path.sv) : start pulse only in IDLE
// ------------------------------------------------------------
module act_patch_gen_sva (
	input logic       clk,
	input logic       rst_n,
	input logic       i_tile_start,
	input logic [2:0] state
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_start_idle : assert property (i_tile_start |-> (state == 3'd0))
		else `uvm_error("SVA", "act_patch_gen : tile_start while not IDLE (start dropped)");
endmodule

module fc_gen_sva (
	input logic       clk,
	input logic       rst_n,
	input logic       i_tile_start,
	input logic [1:0] state
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_start_idle : assert property (i_tile_start |-> (state == 2'd0))
		else `uvm_error("SVA", "fc_gen : tile_start while not IDLE (start dropped)");
endmodule

module act_ld_unit_sva (
	input logic clk,
	input logic rst_n,
	input logic i_ld_start,
	input logic state
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_start_idle : assert property (i_ld_start |-> (state == 1'b0))
		else `uvm_error("SVA", "act_ld_unit : ld_start while not IDLE (start dropped)");
endmodule


// ------------------------------------------------------------
// single_pe (pe_core.sv) : result pulse is 1 clk
// ------------------------------------------------------------
module single_pe_sva (
	input logic clk,
	input logic rst_n,
	input logic o_result_valid
);
	import uvm_pkg::*;
	default clocking cb @(posedge clk); endclocking
	default disable iff (!rst_n);
	a_result_pulse : assert property (o_result_valid |=> !o_result_valid)
		else `uvm_error("SVA", "single_pe : result_valid longer than 1 clk");
endmodule


// ------------------------------------------------------------
// bind collection (instantiated in tb_top)
//   port names match the target module's signal names so they connect with .*
// ------------------------------------------------------------
module cnn_sva_bind;
	// top_cnn ports (port names differ, so connect by name)
	bind top_cnn       cnn_top_sva       u_top_sva           (.clk(clk), .rst_n(rst_n),
		.start_valid(i_start_valid), .start_ready(o_start_ready), .busy(o_busy),
		.irq_en(i_irq_en), .irq_clear(i_irq_clear), .final_result(o_final_result),
		.done_status(o_done_status), .irq(o_irq), .cnn_state(o_cnn_state));
	bind cnn_cntl      cnn_cntl_sva      u_cnn_cntl_sva      (.*);
	bind pe_cntl       pe_cntl_sva       u_pe_cntl_sva       (.*);
	// o_final_data is signed and state is an enum, so connect by name instead of .* (which requires matching types)
	bind post_process  post_process_sva  u_post_process_sva  (.*, .o_final_data(o_final_data));
	bind output_fifo   output_fifo_sva   u_output_fifo_sva   (.*);
	bind pooling_unit  pooling_unit_sva  u_pooling_unit_sva  (.*);
	bind result_buf    result_buf_sva    u_result_buf_sva    (.*);
	bind wgt_ld_unit   wgt_ld_unit_sva   u_wgt_ld_unit_sva   (.*);
	bind wgt_patch_gen wgt_patch_gen_sva u_wgt_patch_gen_sva (.*);
	// read-side signals are taken from the WGT_PATCH_GEN instance inside wgt_path
	bind wgt_path      wgt_path_sva      u_wgt_path_sva      (.clk(clk), .rst_n(rst_n),
		.buf_we(buf_we), .buf_waddr(buf_waddr),
		.rd_active(WGT_PATCH_GEN.chunk_active), .rd_half(WGT_PATCH_GEN.rd_half_r));
	bind act_patch_gen act_patch_gen_sva u_act_patch_gen_sva (.clk(clk), .rst_n(rst_n), .i_tile_start(i_tile_start), .state(state));
	bind fc_gen        fc_gen_sva        u_fc_gen_sva        (.clk(clk), .rst_n(rst_n), .i_tile_start(i_tile_start), .state(state));
	bind act_ld_unit   act_ld_unit_sva   u_act_ld_unit_sva   (.clk(clk), .rst_n(rst_n), .i_ld_start(i_ld_start), .state(state));
	bind single_pe     single_pe_sva     u_single_pe_sva     (.*);
endmodule
