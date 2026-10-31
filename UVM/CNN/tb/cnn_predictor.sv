// ============================================================
// cnn_predictor : when START is observed, builds the golden from the RAM contents at that moment (backdoor)
//   reads img_agent.image_memory / wgt_agent.ram_memory (handles set by env)
//   The DUT does not write the RAMs during inference, so the contents at START are exactly what the DUT reads
// ============================================================
class cnn_predictor extends uvm_subscriber #(cnn_host_event);
	`uvm_component_utils(cnn_predictor)

	uvm_analysis_port #(cnn_golden) exp_ap;

	cnn_mem_model image_memory;
	cnn_mem_model ram_memory;
	cnn_env_cfg   cfg;
	cnn_ref_model ref_model;
	int           pred_cnt;

	function new(string name = "cnn_predictor", uvm_component parent);
		super.new(name, parent);
		exp_ap = new("exp_ap", this);
		pred_cnt = 0;
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		if (!uvm_config_db#(cnn_env_cfg)::get(this, "", "cfg", cfg)) begin
			`uvm_fatal(get_type_name(), "No find cnn_env_cfg(cfg) in config_db")
		end
		ref_model = cnn_ref_model::type_id::create("ref_model");
		ref_model.set_quant(cfg.qm, cfg.qs);
	endfunction

	function void write(cnn_host_event t);
		cnn_infer_item item;
		cnn_golden     g;

		if (t.kind != EV_START) return;
		if ((image_memory == null) || (ram_memory == null)) begin
			`uvm_fatal(get_type_name(), "memory handles are null")
		end

		item = cnn_infer_item::type_id::create("pred_item");
		item.unpack_from_mem(image_memory, ram_memory);
		item.data_mode = cnn_infer_item::last_mode;

		g = ref_model.run(item);
		g.start_cycle = t.cycle;
		pred_cnt++;

		`uvm_info(get_type_name(), $sformatf("Golden #%0d : %s", pred_cnt, g.convert2string()), UVM_LOW)
		`uvm_info(get_type_name(), $sformatf("Stimulus   : %s", item.convert2string()), UVM_MEDIUM)
		exp_ap.write(g);
	endfunction
endclass
