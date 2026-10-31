// ============================================================
// cnn_image_responder : img_agent's responder. answers cnn_img_if like a synchronous Image RAM
//   A reactive driver with no sequencer : returns image_memory.read(addr) on the clk after the address.
//   RAM reads are not checked here. Reading a wrong address shows up in layer_scb / scoreboard.
//   The read count and out-of-range read count are tallied by the memory model and printed in report_phase.
// ============================================================
class cnn_image_responder extends uvm_component;
	`uvm_component_utils(cnn_image_responder)

	virtual cnn_img_if img_vif;
	cnn_mem_model      memory;      // img_agent's image_memory, set by img_agent right after create

	function new(string name = "cnn_image_responder", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		if (!uvm_config_db#(virtual cnn_img_if)::get(this, "", "img_vif", img_vif)) begin
			`uvm_fatal(get_type_name(), "No find Virtual Interface(img_vif) in config_db")
		end
	endfunction

	virtual task run_phase(uvm_phase phase);
		bit [31:0] d;
		if (memory == null) begin
			`uvm_fatal(get_type_name(), "image_memory handle is null")
		end
		img_vif.rsp_cb.rdata <= '0;
		forever begin
			@(img_vif.rsp_cb);
			d = memory.read(int'(img_vif.rsp_cb.rd_addr));
			img_vif.rsp_cb.rdata <= d[23:0];
		end
	endtask

	function void report_phase(uvm_phase phase);
		super.report_phase(phase);
		if (memory != null) begin
			`uvm_info(get_type_name(), memory.convert2string(), UVM_LOW)
		end
	endfunction
endclass
