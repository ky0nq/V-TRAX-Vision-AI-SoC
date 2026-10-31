// ============================================================
// cnn_img_agent : img_agent = image_memory + image_responder (Image RAM, cnn_img_if)
//   image_memory  : Image RAM contents (4096 x 24bit). owned here; env shares the handle with
//                   virtual_sequencer (stimulus load) and predictor (golden at START)
//   image_responder : returns image_memory.read() to the DUT read address
// ============================================================
class cnn_img_agent extends uvm_agent;
	`uvm_component_utils(cnn_img_agent)

	cnn_mem_model       image_memory;
	cnn_image_responder image_responder;

	function new(string name = "cnn_img_agent", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		image_memory = cnn_mem_model::type_id::create("image_memory");
		image_memory.configure(CNN_IMG_WORDS, 24);

		image_responder = cnn_image_responder::type_id::create("image_responder", this);
		image_responder.memory = image_memory;
	endfunction
endclass
