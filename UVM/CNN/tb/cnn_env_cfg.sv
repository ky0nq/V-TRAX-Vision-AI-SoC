// ============================================================
// cnn_env_cfg : environment configuration object
//   Created by the test and passed down via uvm_config_db ("cfg").
// ============================================================
class cnn_env_cfg extends uvm_object;
	`uvm_object_utils(cnn_env_cfg)

	// ---- configuration ----
	bit          host_active        = 1'b1;   // make host_agent active
	bit          enable_layer_check = 1'b1;   // layer_scb : compare input_buf against golden after every layer (white-box)
	bit          enable_coverage    = 1'b1;

	// ---- timeouts (in clks) ----
	int unsigned done_timeout_cycles  = 3_000_000;   // one inference ~ 420k clk
	int unsigned ready_timeout_cycles = 100_000;

	// ---- reporting ----
	int          max_layer_errors     = 16;          // max number of layer-compare mismatches printed

	// ---- Requant M / S (same values as the DUT parameters. used by the golden model) ----
	int          qm[4];
	int          qs[4];

	function new(string name = "cnn_env_cfg");
		super.new(name);
		qm[0] = CNN_L0_QM;  qs[0] = CNN_L0_QS;
		qm[1] = CNN_L1_QM;  qs[1] = CNN_L1_QS;
		qm[2] = CNN_L2_QM;  qs[2] = CNN_L2_QS;
		qm[3] = CNN_L3_QM;  qs[3] = CNN_L3_QS;
	endfunction

	function string convert2string();
		return $sformatf("host_active=%0b layer_check=%0b cov=%0b done_timeout=%0d qm=%p qs=%p",
			host_active, enable_layer_check, enable_coverage, done_timeout_cycles, qm, qs);
	endfunction
endclass
