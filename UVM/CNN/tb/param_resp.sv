// ============================================================
// cnn_wgt_param_responder : wgt_agent's responder. answers cnn_wgt_if like a synchronous Weight + Bias(param) RAM
//   A reactive driver with no sequencer : returns ram_memory.read(addr) on the clk after the address.
//   RAM reads are not checked here. Reading a wrong address shows up in layer_scb / scoreboard.
//   The read count and out-of-range read count are tallied by the memory model and printed in report_phase.
// ============================================================
class cnn_wgt_param_responder extends uvm_component;
	`uvm_component_utils(cnn_wgt_param_responder)

	virtual cnn_wgt_if wgt_vif;
	cnn_mem_model      memory;      // wgt_agent's ram_memory, set by wgt_agent right after create

	function new(string name = "cnn_wgt_param_responder", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		if (!uvm_config_db#(virtual cnn_wgt_if)::get(this, "", "wgt_vif", wgt_vif)) begin
			`uvm_fatal(get_type_name(), "No find Virtual Interface(wgt_vif) in config_db")
		end
	endfunction

	virtual task run_phase(uvm_phase phase);
		bit [31:0] d;
		if (memory == null) begin
			`uvm_fatal(get_type_name(), "ram_memory handle is null")
		end
		wgt_vif.rsp_cb.rdata <= '0;
		forever begin
			@(wgt_vif.rsp_cb);
			d = memory.read(int'(wgt_vif.rsp_cb.rd_addr));
			wgt_vif.rsp_cb.rdata <= d;
		end
	endtask

	function void report_phase(uvm_phase phase);
		super.report_phase(phase);
		if (memory != null) begin
			`uvm_info(get_type_name(), memory.convert2string(), UVM_LOW)
		end
	endfunction
endclass
