// ============================================================
// cnn_env
//   The DUT is top_cnn (no AXI4-Lite wrapper). When host_agent issues start, the DUT runs while reading both RAMs.
//   host_agent        : sequencer / driver / monitor on cnn_ctrl_if. control pins (start / done / irq) + reset
//   img_agent         : image_memory + image_responder on cnn_img_if (Image RAM)
//   wgt_agent         : ram_memory + wgt_param_responder on cnn_wgt_if (shared Weight + Bias RAM)
//   virtual_sequencer : host_agent.sequencer + image_memory / ram_memory handles
//   predictor         : image_memory / ram_memory contents at START -> golden
//   scoreboard        : o_final_result vs golden, irq
//   layer_scb         : input_buf (act_buf_probe) vs golden after every layer (white-box)
//   coverage          : functional coverage
// ============================================================
class cnn_env extends uvm_env;
	`uvm_component_utils(cnn_env)

	cnn_env_cfg           cfg;

	cnn_host_agent        host_agent;
	cnn_img_agent         img_agent;
	cnn_wgt_agent         wgt_agent;

	cnn_virtual_sequencer virtual_sequencer;
	cnn_predictor         predictor;
	cnn_scoreboard        scoreboard;
	cnn_layer_scb         layer_scb;
	cnn_coverage          coverage;

	function new(string name = "cnn_env", uvm_component parent);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);

		// ---- cfg ----
		if (!uvm_config_db#(cnn_env_cfg)::get(this, "", "cfg", cfg)) begin
			cfg = cnn_env_cfg::type_id::create("cfg");
			`uvm_info(get_type_name(), "No cfg in config_db : using defaults", UVM_LOW)
		end
		uvm_config_db#(cnn_env_cfg)::set(this, "*", "cfg", cfg);
		`uvm_info(get_type_name(), $sformatf("cfg : %s", cfg.convert2string()), UVM_LOW)

		// ---- agents ----
		if (!cfg.host_active) begin
			uvm_config_db#(uvm_bitstream_t)::set(this, "host_agent", "is_active", UVM_PASSIVE);
		end
		host_agent = cnn_host_agent::type_id::create("host_agent", this);
		img_agent  = cnn_img_agent::type_id::create("img_agent", this);    // creates image_memory
		wgt_agent  = cnn_wgt_agent::type_id::create("wgt_agent", this);    // creates ram_memory

		// ---- virtual sequencer / checking / coverage ----
		virtual_sequencer = cnn_virtual_sequencer::type_id::create("virtual_sequencer", this);
		predictor         = cnn_predictor::type_id::create("predictor", this);
		scoreboard        = cnn_scoreboard::type_id::create("scoreboard", this);
		layer_scb         = cnn_layer_scb::type_id::create("layer_scb", this);
		if (cfg.enable_coverage) begin
			coverage = cnn_coverage::type_id::create("coverage", this);
		end
	endfunction

	function void connect_phase(uvm_phase phase);
		super.connect_phase(phase);

		// host_agent.monitor events -> predictor / scoreboard / layer_scb / coverage
		host_agent.ap.connect(predictor.analysis_export);
		host_agent.ap.connect(scoreboard.host_imp);
		host_agent.ap.connect(layer_scb.host_imp);

		// golden -> scoreboard / layer_scb / coverage
		predictor.exp_ap.connect(scoreboard.exp_imp);
		predictor.exp_ap.connect(layer_scb.exp_imp);

		if (cfg.enable_coverage) begin
			host_agent.ap.connect(coverage.host_imp);
			predictor.exp_ap.connect(coverage.exp_imp);
		end

		// the agents own the memory models; predictor reads them at START
		predictor.image_memory = img_agent.image_memory;
		predictor.ram_memory   = wgt_agent.ram_memory;

		// virtual sequencer
		virtual_sequencer.host_sequencer = host_agent.sequencer;
		virtual_sequencer.image_memory   = img_agent.image_memory;
		virtual_sequencer.ram_memory     = wgt_agent.ram_memory;
		virtual_sequencer.cfg            = cfg;
	endfunction
endclass
