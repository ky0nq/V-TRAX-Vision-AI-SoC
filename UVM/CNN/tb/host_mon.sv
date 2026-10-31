// ============================================================
// cnn_host_monitor : host_agent's monitor. observes cnn_ctrl_if every clk and emits events
//   EV_RESET      rst_n falls to 0
//   EV_START      start_valid && start_ready
//   EV_LAYER_DONE cnn_state leaves C_LAYER_END(9) -> that layer's results are fully written to input_buf
//   EV_DONE       done_status rises (final_result valid)
//   EV_IRQ_CLEAR  irq_clear observed
// ============================================================
class cnn_host_monitor extends uvm_monitor;
	`uvm_component_utils(cnn_host_monitor)

	virtual cnn_ctrl_if ctrl_vif;
	uvm_analysis_port #(cnn_host_event) ap;

	longint cycle;
	longint start_cycle;
	int     start_cnt, done_cnt, layer_done_cnt, reset_cnt;

	function new(string name = "cnn_host_monitor", uvm_component parent);
		super.new(name, parent);
		ap = new("ap", this);
		cycle = 0; start_cycle = 0;
		start_cnt = 0; done_cnt = 0; layer_done_cnt = 0; reset_cnt = 0;
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		if (!uvm_config_db#(virtual cnn_ctrl_if)::get(this, "", "ctrl_vif", ctrl_vif)) begin
			`uvm_fatal(get_type_name(), "No find Virtual Interface(ctrl_vif) in config_db")
		end
	endfunction

	local function cnn_host_event mk(cnn_host_kind_e kind);
		cnn_host_event e;
		e = cnn_host_event::type_id::create("host_event");
		e.kind         = kind;
		e.cycle        = cycle;
		e.irq_en       = ctrl_vif.mon_cb.irq_en;
		e.irq          = ctrl_vif.mon_cb.irq;
		e.final_result = ctrl_vif.mon_cb.final_result;
		e.layer_idx    = ctrl_vif.mon_cb.layer_idx;
		e.cnn_state    = ctrl_vif.mon_cb.cnn_state;
		return e;
	endfunction

	virtual task run_phase(uvm_phase phase);
		cnn_host_event e;
		bit in_reset;
		bit prev_done;
		int prev_state;
		int prev_layer;

		in_reset   = 1'b1;
		prev_done  = 1'b0;
		prev_state = CS_IDLE;
		prev_layer = 0;

		forever begin
			@(ctrl_vif.mon_cb);

			// ---- reset ----
			if (ctrl_vif.rst_n !== 1'b1) begin
				if (!in_reset) begin
					in_reset = 1'b1;
					reset_cnt++;
					e = mk(EV_RESET);
					`uvm_info(get_type_name(), $sformatf("Observed : %s", e.convert2string()), UVM_MEDIUM)
					ap.write(e);
				end
				prev_done  = 1'b0;
				prev_state = CS_IDLE;
				prev_layer = 0;
				continue;
			end
			if (in_reset) begin
				in_reset = 1'b0;
				cycle    = 0;
			end
			cycle++;

			// ---- start fire ----
			if ((ctrl_vif.mon_cb.start_valid === 1'b1) && (ctrl_vif.mon_cb.start_ready === 1'b1)) begin
				start_cnt++;
				start_cycle = cycle;
				e = mk(EV_START);
				`uvm_info(get_type_name(), $sformatf("Observed : %s", e.convert2string()), UVM_MEDIUM)
				ap.write(e);
			end

			// ---- layer end : the moment it leaves C_LAYER_END ----
			if ((prev_state == CS_LAYER_END) && (ctrl_vif.mon_cb.cnn_state != CS_LAYER_END)) begin
				layer_done_cnt++;
				e = mk(EV_LAYER_DONE);
				e.layer_idx = prev_layer;
				`uvm_info(get_type_name(), $sformatf("Observed : %s", e.convert2string()), UVM_MEDIUM)
				ap.write(e);
			end

			// ---- done rise ----
			if ((ctrl_vif.mon_cb.done_status === 1'b1) && !prev_done) begin
				done_cnt++;
				e = mk(EV_DONE);
				e.latency = cycle - start_cycle;
				`uvm_info(get_type_name(), $sformatf("Observed : %s", e.convert2string()), UVM_LOW)
				ap.write(e);
			end

			// ---- irq_clear ----
			if (ctrl_vif.mon_cb.irq_clear === 1'b1) begin
				e = mk(EV_IRQ_CLEAR);
				`uvm_info(get_type_name(), $sformatf("Observed : %s", e.convert2string()), UVM_MEDIUM)
				ap.write(e);
			end

			prev_done  = (ctrl_vif.mon_cb.done_status === 1'b1);
			prev_state = ctrl_vif.mon_cb.cnn_state;
			prev_layer = ctrl_vif.mon_cb.layer_idx;
		end
	endtask

	function void report_phase(uvm_phase phase);
		super.report_phase(phase);
		`uvm_info(get_type_name(), $sformatf("starts=%0d dones=%0d layer_dones=%0d resets=%0d cycles=%0d",
			start_cnt, done_cnt, layer_done_cnt, reset_cnt, cycle), UVM_LOW)
	endfunction
endclass
