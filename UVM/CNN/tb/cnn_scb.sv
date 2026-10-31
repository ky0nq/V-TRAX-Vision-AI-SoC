// ============================================================
// cnn_scoreboard : compares the final result (o_final_result) against the golden
//   predictor -> exp_imp : expected value at START time (queued in order)
//   host_agent.monitor -> host_imp : on DONE, compare against the expected value at the queue front
// ============================================================
`uvm_analysis_imp_decl(_sb_exp)
`uvm_analysis_imp_decl(_sb_host)

class cnn_scoreboard extends uvm_scoreboard;
	`uvm_component_utils(cnn_scoreboard)

	uvm_analysis_imp_sb_exp  #(cnn_golden,     cnn_scoreboard) exp_imp;
	uvm_analysis_imp_sb_host #(cnn_host_event, cnn_scoreboard) host_imp;

	cnn_golden exp_q[$];

	int     start_cnt   = 0;
	int     infer_cnt   = 0;
	int     pass_cnt    = 0;
	int     fail_cnt    = 0;
	int     reset_cnt   = 0;
	int     irq_err_cnt = 0;
	longint lat_min, lat_max, lat_sum;

	function new(string name = "cnn_scoreboard", uvm_component parent);
		super.new(name, parent);
		exp_imp = new("exp_imp", this);
		host_imp = new("host_imp", this);
		lat_min = 64'h7FFF_FFFF_FFFF_FFFF;
		lat_max = 0;
		lat_sum = 0;
	endfunction

	// ==================================================
	// predictor -> scoreboard
	// ==================================================
	function void write_sb_exp(cnn_golden g);
		exp_q.push_back(g);
		`uvm_info(get_type_name(), $sformatf("Expected queued : final_q=%0d (pending=%0d)", g.final_q, exp_q.size()), UVM_MEDIUM)
	endfunction

	// ==================================================
	// host_agent monitor -> scoreboard
	// ==================================================
	function void write_sb_host(cnn_host_event t);
		cnn_golden g;

		case (t.kind)
			EV_RESET: begin
				reset_cnt++;
				if (exp_q.size() > 0) begin
					`uvm_info(get_type_name(), $sformatf("RESET : discarding %0d pending expected result(s)", exp_q.size()), UVM_LOW)
					exp_q.delete();
				end
			end

			EV_START: begin
				start_cnt++;
			end

			EV_DONE: begin
				infer_cnt++;
				if (exp_q.size() == 0) begin
					fail_cnt++;
					`uvm_error(get_type_name(), $sformatf("DONE observed (result=%0d) but no expected result pending", t.final_result))
					return;
				end
				g = exp_q.pop_front();

				// latency
				lat_sum += t.latency;
				if (t.latency < lat_min) lat_min = t.latency;
				if (t.latency > lat_max) lat_max = t.latency;

				// result compare
				if (t.final_result == g.final_q) begin
					pass_cnt++;
					`uvm_info(get_type_name(), $sformatf("INFER #%0d PASS : final_result=%0d (mode=%s latency=%0d clk)",
						infer_cnt, t.final_result, g.data_mode.name(), t.latency), UVM_LOW)
				end
				else begin
					fail_cnt++;
					`uvm_error(get_type_name(), $sformatf("INFER #%0d FAIL : DUT=%0d EXP=%0d (mode=%s fc2 acc=%0d sum=%0d rounded=%0d latency=%0d clk)",
						infer_cnt, t.final_result, g.final_q, g.data_mode.name(),
						g.final_acc, g.final_sum, g.final_rounded, t.latency))
				end

				// irq = irq_en && done_status
				if (t.irq !== t.irq_en) begin
					irq_err_cnt++;
					`uvm_error(get_type_name(), $sformatf("IRQ mismatch at DONE : irq=%0b irq_en=%0b", t.irq, t.irq_en))
				end
			end

			default: begin
			end
		endcase
	endfunction

	function void check_phase(uvm_phase phase);
		super.check_phase(phase);
		if (exp_q.size() > 0) begin
			`uvm_error(get_type_name(), $sformatf("%0d inference(s) started but never reported DONE", exp_q.size()))
		end
	endfunction

	function void report_phase(uvm_phase phase);
		longint lat_avg;
		super.report_phase(phase);
		lat_avg = (infer_cnt > 0) ? (lat_sum / infer_cnt) : 0;
		`uvm_info(get_type_name(),
			$sformatf(
				{"\n",
				"========================================\n",
				"         CNN SCOREBOARD RESULT\n",
				"========================================\n",
				"    Start Count   : %0d\n",
				"    Done Count    : %0d\n",
				"    Pass Count    : %0d\n",
				"    Fail Count    : %0d\n",
				"    IRQ Errors    : %0d\n",
				"    Resets        : %0d\n",
				"    Latency clk   : min %0d / avg %0d / max %0d\n",
				"========================================"},
				start_cnt, infer_cnt, pass_cnt, fail_cnt, irq_err_cnt, reset_cnt,
				(infer_cnt > 0) ? lat_min : 0, lat_avg, lat_max
			),
			UVM_LOW
		)
	endfunction
endclass
