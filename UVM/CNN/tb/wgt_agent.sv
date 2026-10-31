// ============================================================
// cnn_wgt_agent : wgt_agent = ram_memory + wgt_param_responder (shared Weight + Bias RAM, cnn_wgt_if)
//   ram_memory          : 45293 x 32bit (0 .. 45249 weight, 45250 .. 45292 bias). owned here; env shares the
//                         handle with virtual_sequencer (stimulus load) and predictor (golden at START)
//   wgt_param_responder : returns ram_memory.read() to the DUT read address
// ============================================================
class cnn_wgt_agent extends uvm_agent;
	`uvm_component_utils(cnn_wgt_agent)

	cnn_mem_model           ram_memory;
	cnn_wgt_param_responder wgt_param_responder;

	function new(string name = "cnn_wgt_agent", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		ram_memory = cnn_mem_model::type_id::create("ram_memory");
		ram_memory.configure(CNN_RAM_WORDS, 32);

		wgt_param_responder = cnn_wgt_param_responder::type_id::create("wgt_param_responder", this);
		wgt_param_responder.memory = ram_memory;
	endfunction
endclass
