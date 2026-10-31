// ============================================================
// cnn_layer_scb : layer_scb. compares input_buf (white-box, via act_buf_probe) against the golden each time a layer finishes
//   Layer 0 (Conv0+Pool) -> REGION_B   32x32x6   word = 8192 + pos*2 + ch/3
//   Layer 1 (Conv1)      -> REGION_A   32x32x4   word =    0 + pos*2 + ch/3   (second word: lane0 only)
//   Layer 2 (fc1)        -> REGION_B   32        word = 8192 + ch/3           (last word: lane0,1 only)
//   Layer 3 (fc2)        -> not written to memory (scoreboard checks it via o_final_result)
//   does nothing when cfg.enable_layer_check = 0
// ============================================================
`uvm_analysis_imp_decl(_lscb_exp)
`uvm_analysis_imp_decl(_lscb_host)

class cnn_layer_scb extends uvm_component;
	`uvm_component_utils(cnn_layer_scb)

	uvm_analysis_imp_lscb_exp  #(cnn_golden,     cnn_layer_scb) exp_imp;
	uvm_analysis_imp_lscb_host #(cnn_host_event, cnn_layer_scb) host_imp;

	cnn_act_buf_probe_base act_buf_probe;
	cnn_env_cfg            cfg;

	cnn_golden cur;
	cnn_golden exp_q[$];

	int layer_pass[4];
	int layer_fail[4];
	int words_checked  = 0;
	int lanes_mismatch = 0;

	function new(string name = "cnn_layer_scb", uvm_component parent);
		super.new(name, parent);
		exp_imp  = new("exp_imp", this);
		host_imp = new("host_imp", this);
		cur = null;
		for (int l = 0; l < 4; l++) begin
			layer_pass[l] = 0;
			layer_fail[l] = 0;
		end
	endfunction

	function void build_phase(uvm_phase phase);
		super.build_phase(phase);
		if (!uvm_config_db#(cnn_env_cfg)::get(this, "", "cfg", cfg)) begin
			`uvm_fatal(get_type_name(), "No find cnn_env_cfg(cfg) in config_db")
		end
		if (cfg.enable_layer_check) begin
			if (!uvm_config_db#(cnn_act_buf_probe_base)::get(this, "", "act_buf_probe", act_buf_probe)) begin
				`uvm_fatal(get_type_name(), "No find cnn_act_buf_probe_base(act_buf_probe) in config_db (needed for layer check)")
			end
		end
	endfunction

	function void write_lscb_exp(cnn_golden g);
		if (!cfg.enable_layer_check) return;     // don't queue when disabled (otherwise one golden per inference would be left over)
		exp_q.push_back(g);
	endfunction

	function void write_lscb_host(cnn_host_event t);
		case (t.kind)
			EV_RESET: begin
				cur = null;
				exp_q.delete();
			end
			EV_START: begin
				cur = null;
			end
			EV_LAYER_DONE: begin
				if (!cfg.enable_layer_check) return;
				if (t.layer_idx > 2) return;                 // fc2 does not write to memory
				if (cur == null) begin
					if (exp_q.size() > 0) cur = exp_q.pop_front();
					else begin
						`uvm_warning(get_type_name(), $sformatf("LAYER_DONE(%0d) but no golden available", t.layer_idx))
						return;
					end
				end
				check_layer(t.layer_idx);
			end
			EV_DONE: begin
				// discard the golden of an inference that saw no LAYER_DONE at all, so it does not linger
				if ((cur == null) && (exp_q.size() > 0)) void'(exp_q.pop_front());
				cur = null;
			end
			default: begin
			end
		endcase
	endfunction

	// ------------------------------------------------------------
	function void check_layer(int layer);
		cnn_exp_word_arr_t words;
		logic [23:0]       got;
		int                mism;
		int                base, wpp, ch;

		words = cur.exp_words(layer);
		mism  = 0;
		case (layer)
			0: begin base = CNN_REGION_B; wpp = 2;  ch = CNN_L1_IN_C;  end
			1: begin base = CNN_REGION_A; wpp = 2;  ch = CNN_L1_OUT_C; end
			default: begin base = CNN_REGION_B; wpp = 11; ch = CNN_L2_OUT_C; end
		endcase

		foreach (words[i]) begin
			got = act_buf_probe.act_buf_read(words[i].addr);
			for (int c = 0; c < 3; c++) begin
				if (!words[i].be[c]) continue;
				if (got[8*c +: 8] !== words[i].data[8*c +: 8]) begin
					mism++;
					if (mism <= cfg.max_layer_errors) begin
						int off, pos, g, chn;
						off = words[i].addr - base;
						pos = off / wpp;
						g   = off % wpp;
						chn = g * 3 + c;
						`uvm_error(get_type_name(), $sformatf("LAYER %0d mismatch : ibuf[%0d] lane%0d (pos=%0d y=%0d x=%0d ch=%0d) DUT=%0d EXP=%0d (word DUT=0x%06h EXP=0x%06h be=%03b)",
							layer, words[i].addr, c, pos, (layer < 2) ? pos / CNN_L1_IN_W : 0, (layer < 2) ? pos % CNN_L1_IN_W : 0, chn,
							$signed(got[8*c +: 8]), $signed(words[i].data[8*c +: 8]), got, words[i].data, words[i].be))
					end
				end
			end
		end

		words_checked  += words.size();
		lanes_mismatch += mism;
		if (mism == 0) begin
			layer_pass[layer]++;
			`uvm_info(get_type_name(), $sformatf("LAYER %0d PASS : %0d words match golden", layer, words.size()), UVM_LOW)
		end
		else begin
			layer_fail[layer]++;
			`uvm_error(get_type_name(), $sformatf("LAYER %0d FAIL : %0d lane mismatch(es) in %0d words (first %0d printed)",
				layer, mism, words.size(), cfg.max_layer_errors))
		end
	endfunction

	function void report_phase(uvm_phase phase);
		super.report_phase(phase);
		`uvm_info(get_type_name(),
			$sformatf(
				{"\n",
				"========================================\n",
				"       CNN LAYER SCOREBOARD RESULT\n",
				"========================================\n",
				"    enabled        : %0b\n",
				"    Layer0 pass/fail : %0d / %0d\n",
				"    Layer1 pass/fail : %0d / %0d\n",
				"    Layer2 pass/fail : %0d / %0d\n",
				"    words checked  : %0d\n",
				"    lane mismatch  : %0d\n",
				"========================================"},
				cfg.enable_layer_check,
				layer_pass[0], layer_fail[0], layer_pass[1], layer_fail[1], layer_pass[2], layer_fail[2],
				words_checked, lanes_mismatch
			),
			UVM_LOW
		)
	endfunction
endclass
