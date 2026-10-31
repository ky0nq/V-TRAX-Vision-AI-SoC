// ============================================================
// cnn_virtual_sequencer : virtual sequencer
//   holds host_agent's sequencer and the two memory handles (for backdoor stimulus load)
// ============================================================
class cnn_virtual_sequencer extends uvm_sequencer;
	`uvm_component_utils(cnn_virtual_sequencer)

	cnn_host_sequencer host_sequencer;   // host_agent.sequencer
	cnn_mem_model      image_memory;     // img_agent.image_memory
	cnn_mem_model      ram_memory;       // wgt_agent.ram_memory
	cnn_env_cfg        cfg;

	function new(string name = "cnn_virtual_sequencer", uvm_component parent);
		super.new(name, parent);
	endfunction
endclass
