// ============================================================
// cnn_test_lib
//   cnn_base_test   : 1 inference (DM_SMALL)                       make run TEST=cnn_base_test
//   cnn_random_test : N random-pattern inferences (+NUM_INFER=n)   make run TEST=cnn_random_test
//   cnn_corner_test : corner patterns (ZERO/MAX/MIN/ALT/SPARSE/FULL)
//   cnn_file_test   : hex files (+IMG_HEX= +RAM_HEX= | +WGT_HEX= +BIAS_HEX=) [+EXP_RESULT=n]
//   cnn_irq_test    : irq_en / irq / irq_clear
//   cnn_reset_test  : reset in the middle of an inference (+RESET_AFTER=n)
//   cnn_cov_test    : functional coverage closure, fills every cnn_coverage bin alone (24 inferences + irq / reset scenarios)
//
//   common plusargs : +DONE_TIMEOUT=<clk>  +NO_LAYER_CHECK  +NO_COV
// ============================================================

// ------------------------------------------------------------
class cnn_base_test extends uvm_test;
	`uvm_component_utils(cnn_base_test)

	cnn_env     env;
	cnn_env_cfg cfg;

	function new(string name = "cnn_base_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		cfg = cnn_env_cfg::type_id::create("cfg");
		configure_cfg();
		uvm_config_db#(cnn_env_cfg)::set(this, "*", "cfg", cfg);
		env = cnn_env::type_id::create("env", this);
	endfunction

	virtual function void configure_cfg();
		int unsigned v;
		if ($value$plusargs("DONE_TIMEOUT=%d", v)) cfg.done_timeout_cycles = v;
		if ($test$plusargs("NO_LAYER_CHECK"))      cfg.enable_layer_check = 1'b0;
		if ($test$plusargs("NO_COV"))              cfg.enable_coverage    = 1'b0;
	endfunction

	function void end_of_elaboration_phase(uvm_phase phase);
		super.end_of_elaboration_phase(phase);
		uvm_top.print_topology();
	endfunction

	virtual task run_phase(uvm_phase phase);
		phase.raise_objection(this);
		main_body();
		#100;   // delay for stable state
		phase.drop_objection(this);
	endtask

	// overridden by derived tests
	virtual task main_body();
		cnn_infer_vseq seq;
		seq = cnn_infer_vseq::type_id::create("seq");
		seq.data_mode  = DM_SMALL;
		seq.irq_en     = 1'b1;
		seq.sparse_pct = 10;
		seq.start(env.virtual_sequencer);
	endtask

	function void report_phase(uvm_phase phase);
		uvm_report_server svr;
		super.report_phase(phase);
		svr = uvm_report_server::get_server();
		if ((svr.get_severity_count(UVM_ERROR) == 0) && (svr.get_severity_count(UVM_FATAL) == 0)) begin
			`uvm_info(get_type_name(), "\n========================================\n           TEST PASSED\n========================================", UVM_NONE)
		end
		else begin
			`uvm_info(get_type_name(), $sformatf("\n========================================\n           TEST FAILED (%0d errors)\n========================================",
				svr.get_severity_count(UVM_ERROR)), UVM_NONE)
		end
	endfunction
endclass

// ------------------------------------------------------------
class cnn_random_test extends cnn_base_test;
	`uvm_component_utils(cnn_random_test)

	function new(string name = "cnn_random_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_multi_infer_vseq seq;
		int unsigned n;
		seq = cnn_multi_infer_vseq::type_id::create("seq");
		if ($value$plusargs("NUM_INFER=%d", n)) begin
			seq.num_infer = n;
		end
		else begin
			if (!seq.randomize()) `uvm_error("TEST", "Seq Randomize Fail!!")
		end
		`uvm_info(get_type_name(), $sformatf("running %0d random inferences", seq.num_infer), UVM_LOW)
		seq.start(env.virtual_sequencer);
	endtask
endclass

// ------------------------------------------------------------
class cnn_corner_test extends cnn_base_test;
	`uvm_component_utils(cnn_corner_test)

	function new(string name = "cnn_corner_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_corner_vseq seq;
		seq = cnn_corner_vseq::type_id::create("seq");
		seq.start(env.virtual_sequencer);
	endtask
endclass

// ------------------------------------------------------------
class cnn_file_test extends cnn_base_test;
	`uvm_component_utils(cnn_file_test)

	function new(string name = "cnn_file_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_file_infer_vseq seq;
		string s;
		int    exp_result;

		seq = cnn_file_infer_vseq::type_id::create("seq");
		if ($value$plusargs("IMG_HEX=%s",  s)) seq.img_hex  = s;
		if ($value$plusargs("RAM_HEX=%s",  s)) seq.ram_hex  = s;
		if ($value$plusargs("WGT_HEX=%s",  s)) seq.wgt_hex  = s;
		if ($value$plusargs("BIAS_HEX=%s", s)) seq.bias_hex = s;
		seq.start(env.virtual_sequencer);

		// if an external golden value is given, compare against it as well
		if ($value$plusargs("EXP_RESULT=%d", exp_result)) begin
			if (seq.last_op.final_result == exp_result[7:0]) begin
				`uvm_info(get_type_name(), $sformatf("external expected %0d matches DUT %0d", exp_result, seq.last_op.final_result), UVM_LOW)
			end
			else begin
				`uvm_error(get_type_name(), $sformatf("external expected %0d but DUT gave %0d", exp_result, seq.last_op.final_result))
			end
		end
	endtask
endclass

// ------------------------------------------------------------
class cnn_irq_test extends cnn_base_test;
	`uvm_component_utils(cnn_irq_test)

	function new(string name = "cnn_irq_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_irq_vseq seq;
		seq = cnn_irq_vseq::type_id::create("seq");
		seq.start(env.virtual_sequencer);
	endtask
endclass

// ------------------------------------------------------------
class cnn_reset_test extends cnn_base_test;
	`uvm_component_utils(cnn_reset_test)

	function new(string name = "cnn_reset_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_reset_vseq seq;
		int unsigned n;
		seq = cnn_reset_vseq::type_id::create("seq");
		if (!seq.randomize()) `uvm_error("TEST", "Seq Randomize Fail!!")
		if ($value$plusargs("RESET_AFTER=%d", n)) seq.reset_after = n;
		seq.start(env.virtual_sequencer);
	endtask
endclass

// ------------------------------------------------------------
class cnn_cov_test extends cnn_base_test;
	`uvm_component_utils(cnn_cov_test)

	function new(string name = "cnn_cov_test", uvm_component parent = null);
		super.new(name, parent);
	endfunction

	virtual task main_body();
		cnn_cov_vseq seq;
		seq = cnn_cov_vseq::type_id::create("seq");
		seq.start(env.virtual_sequencer);
	endtask
endclass
