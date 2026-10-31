// ============================================================
// cnn_host_sequencer : host_agent's sequencer
// ============================================================
class cnn_host_sequencer extends uvm_sequencer #(cnn_host_item);
	`uvm_component_utils(cnn_host_sequencer)

	function new(string name = "cnn_host_sequencer", uvm_component parent);
		super.new(name, parent);
	endfunction
endclass
