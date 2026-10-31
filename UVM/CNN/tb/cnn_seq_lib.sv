// ============================================================
// cnn_seq_lib : virtual sequences
//   cnn_vseq_base        : host_agent operation / memory load helpers
//   cnn_infer_vseq       : 1 inference (stimulus pattern selectable)
//   cnn_multi_infer_vseq : N inferences (random pattern each time)
//   cnn_corner_vseq      : corner patterns (ZERO / MAX / MIN / ALT / SPARSE / FULL) in order
//   cnn_file_infer_vseq  : load from hex files (test compares if +EXP_RESULT is given)
//   cnn_irq_vseq         : irq_en / irq / irq_clear / done_status behavior
//   cnn_reset_vseq       : reset during inference, then a normal inference
//   cnn_cov_vseq         : functional coverage closure (steered results + fixed patterns + hex round trip)
// ============================================================

// ------------------------------------------------------------
class cnn_vseq_base extends uvm_sequence;
	`uvm_object_utils(cnn_vseq_base)
	`uvm_declare_p_sequencer(cnn_virtual_sequencer)

	function new(string name = "cnn_vseq_base");
		super.new(name);
	endfunction

	// build one host_agent operation (seq_item)
	function cnn_host_item mk_op(cnn_host_op_e op_,
	                             bit           irq_en_       = 1'b1,
	                             bit           wait_done_    = 1'b1,
	                             bit           auto_clear_   = 1'b1,
	                             int unsigned  pre_delay_    = 0,
	                             int unsigned  reset_cycles_ = 5);
		cnn_host_item it;
		it = cnn_host_item::type_id::create("host_item");
		it.op           = op_;
		it.irq_en       = irq_en_;
		it.wait_done    = wait_done_;
		it.auto_clear   = auto_clear_;
		it.pre_delay    = pre_delay_;
		it.reset_cycles = reset_cycles_;
		return it;
	endfunction

	// send to host_agent's sequencer (the driver fills the results into the same object)
	task run_op(cnn_host_item it);
		// if host_agent is PASSIVE there is no sequencer, so finish_item would hang forever
		if (p_sequencer.host_sequencer == null) begin
			`uvm_fatal(get_type_name(), "host_sequencer is null (host_agent is PASSIVE) : cannot drive host ops")
		end
		start_item(it, -1, p_sequencer.host_sequencer);
		finish_item(it);
		`uvm_info(get_type_name(), $sformatf("host op done : %s", it.convert2string()), UVM_MEDIUM)
	endtask

	// stimulus -> image_memory / ram_memory (backdoor)
	function void load_item(cnn_infer_item it);
		it.pack_to_mem(p_sequencer.image_memory, p_sequencer.ram_memory);
		`uvm_info(get_type_name(), $sformatf("Loaded stimulus : %s", it.convert2string()), UVM_LOW)
	endfunction

	// whether an INT8 final result falls in the cp_result bin of the target
	function bit in_target(byte signed q, cnn_target_e tgt);
		case (tgt)
			TGT_NEG_SAT : return (q == -128);
			TGT_NEG     : return ((q >= -127) && (q <= -1));
			TGT_ZERO    : return (q == 0);
			TGT_POS     : return ((q >= 1) && (q <= 126));
			TGT_POS_SAT : return (q == 127);
			default     : return 1'b1;
		endcase
	endfunction

	// ------------------------------------------------------------
	// steer the final result into a cp_result bin by choosing the fc2 bias (bias[CNN_L3_PB])
	//   layers 0..2 and the fc2 weights stay as the data pattern made them. only bias[42] changes,
	//   and it is written to RAM like any other bias, so the predictor's golden stays exact.
	//   final = sat8( round( sat32(acc + bias) * M / 2^S ) )  ->  pick the sum for the target, bias = sum - acc
	//   needed because random data almost never hits some bins (e.g. DM_ZERO x zero : |bias| < ~513 out of +-100000)
	// ------------------------------------------------------------
	function void steer_final(cnn_infer_item it, cnn_target_e tgt);
		cnn_ref_model ref_model;
		cnn_golden    g;
		cnn_golden    chk;
		longint       v, sum, b;
		int           m, s;
		byte signed   q;

		if (tgt == TGT_NONE) return;
		m = p_sequencer.cfg.qm[3];
		s = p_sequencer.cfg.qs[3];
		if (m <= 0) begin
			`uvm_warning(get_type_name(), $sformatf("cannot steer the final result : L3 M=%0d", m))
			return;
		end

		// fc2 MAC sum of this stimulus (before bias)
		ref_model = cnn_ref_model::type_id::create("steer_ref");
		ref_model.set_quant(p_sequencer.cfg.qm, p_sequencer.cfg.qs);
		g = ref_model.run(it);

		// target value before INT8 saturation : +-64 is well inside a bin, +-1000 saturates
		case (tgt)
			TGT_NEG_SAT : v = -1000;
			TGT_NEG     : v =   -64;
			TGT_ZERO    : v =     0;
			TGT_POS     : v =    64;
			default     : v =  1000;   // TGT_POS_SAT
		endcase
		sum = (v <<< s) / m;
		b   = sum - longint'(int'(g.final_acc));        // the PE accumulator is 32bit (same wrap as the golden)
		if (b > 64'sd2147483647) begin
			b = 64'sd2147483647;
		end
		else if (b < -64'sd2147483648) begin
			b = -64'sd2147483648;
		end
		it.bias[CNN_L3_PB] = int'(b);

		// check with the golden's own arithmetic
		chk = cnn_golden::type_id::create("steer_chk");
		q   = ref_model.requant(g.final_acc, it.bias[CNN_L3_PB], 3, 1'b0, chk);
		if (!in_target(q, tgt)) begin
			`uvm_warning(get_type_name(), $sformatf("steer %s missed : fc2 acc=%0d bias=%0d -> final=%0d",
				tgt.name(), g.final_acc, it.bias[CNN_L3_PB], q))
		end
		else begin
			`uvm_info(get_type_name(), $sformatf("steer %s : fc2 acc=%0d bias=%0d -> final=%0d",
				tgt.name(), g.final_acc, it.bias[CNN_L3_PB], q), UVM_MEDIUM)
		end
	endfunction
endclass

// ------------------------------------------------------------
// 1 inference
// ------------------------------------------------------------
class cnn_infer_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_infer_vseq)

	rand cnn_data_mode_e data_mode;
	rand bit             irq_en;
	rand int unsigned    sparse_pct;
	rand int unsigned    start_delay;
	cnn_target_e         target;       // TGT_NONE : no steering (not randomized, so existing tests are unchanged)

	cnn_host_item        last_op;      // for checking results

	constraint c_mode {
		data_mode dist { DM_FULL := 4, DM_SMALL := 4, DM_SPARSE := 2, DM_ZERO := 1, DM_MAX := 1, DM_MIN := 1, DM_ALT := 1 };
	}
	constraint c_misc {
		irq_en dist { 1'b1 := 3, 1'b0 := 1 };
		sparse_pct  inside {[1:25]};
		start_delay inside {[0:20]};
	}

	function new(string name = "cnn_infer_vseq");
		super.new(name);
		data_mode   = DM_SMALL;
		irq_en      = 1'b1;
		sparse_pct  = 10;
		start_delay = 0;
		target      = TGT_NONE;
	endfunction

	virtual task body();
		cnn_infer_item it;

		it = cnn_infer_item::type_id::create("infer_item");
		it.sparse_pct = sparse_pct;
		it.fill(data_mode);
		steer_final(it, target);
		load_item(it);

		last_op = mk_op(OP_START, .irq_en_(irq_en), .wait_done_(1'b1), .auto_clear_(1'b1), .pre_delay_(start_delay));
		run_op(last_op);

		if (last_op.timeout || !last_op.done_seen) begin
			`uvm_error(get_type_name(), $sformatf("inference (mode=%s) did not finish", data_mode.name()))
		end
		else begin
			`uvm_info(get_type_name(), $sformatf("inference (mode=%s) done : final_result=%0d cycles=%0d irq=%0b",
				data_mode.name(), last_op.final_result, last_op.cycles, last_op.irq_seen), UVM_LOW)
		end
	endtask
endclass

// ------------------------------------------------------------
// N inferences, random pattern each time
// ------------------------------------------------------------
class cnn_multi_infer_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_multi_infer_vseq)

	rand int unsigned num_infer;

	constraint c_num { num_infer inside {[2:5]}; }

	function new(string name = "cnn_multi_infer_vseq");
		super.new(name);
		num_infer = 3;
	endfunction

	virtual task body();
		cnn_infer_vseq s;
		for (int i = 0; i < num_infer; i++) begin
			s = cnn_infer_vseq::type_id::create($sformatf("infer_%0d", i));
			if (!s.randomize()) begin
				`uvm_error(get_type_name(), "infer_vseq randomize failed")
			end
			`uvm_info(get_type_name(), $sformatf("---- inference %0d / %0d : mode=%s irq_en=%0b ----",
				i + 1, num_infer, s.data_mode.name(), s.irq_en), UVM_LOW)
			s.start(p_sequencer, this);
		end
	endtask
endclass

// ------------------------------------------------------------
// corner patterns
// ------------------------------------------------------------
class cnn_corner_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_corner_vseq)

	cnn_data_mode_e modes[$];

	function new(string name = "cnn_corner_vseq");
		super.new(name);
		modes.push_back(DM_ZERO);
		modes.push_back(DM_MAX);
		modes.push_back(DM_MIN);
		modes.push_back(DM_ALT);
		modes.push_back(DM_SPARSE);
		modes.push_back(DM_FULL);
	endfunction

	virtual task body();
		cnn_infer_vseq s;
		foreach (modes[i]) begin
			s = cnn_infer_vseq::type_id::create($sformatf("corner_%0d", i));
			s.data_mode  = modes[i];
			s.irq_en     = 1'b1;
			s.sparse_pct = 5;
			`uvm_info(get_type_name(), $sformatf("---- corner %0d / %0d : mode=%s ----", i + 1, modes.size(), modes[i].name()), UVM_LOW)
			s.start(p_sequencer, this);
		end
	endtask
endclass

// ------------------------------------------------------------
// load from hex files
//   img_hex : 4096 lines, 24bit word (0x{ch2,ch1,ch0})
//   ram_hex : 45293 lines, 32bit word (weight 0..45249, bias 45250..45292)   or
//   wgt_hex : 45250 lines + bias_hex : 43 lines
// ------------------------------------------------------------
class cnn_file_infer_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_file_infer_vseq)

	string img_hex  = "";
	string ram_hex  = "";
	string wgt_hex  = "";
	string bias_hex = "";
	bit    irq_en   = 1'b1;

	cnn_host_item last_op;

	function new(string name = "cnn_file_infer_vseq");
		super.new(name);
	endfunction

	virtual task body();
		int n;
		if (img_hex == "") begin
			`uvm_fatal(get_type_name(), "img_hex not set (+IMG_HEX=<file>)")
		end
		n = p_sequencer.image_memory.load_hex(img_hex, 0, CNN_IMG_WORDS);
		if (n != CNN_IMG_WORDS) begin
			`uvm_warning(get_type_name(), $sformatf("image file has %0d words (expected %0d)", n, CNN_IMG_WORDS))
		end

		if (ram_hex != "") begin
			n = p_sequencer.ram_memory.load_hex(ram_hex, 0, CNN_RAM_WORDS);
		end
		else begin
			if ((wgt_hex == "") || (bias_hex == "")) begin
				`uvm_fatal(get_type_name(), "need +RAM_HEX=<file> or both +WGT_HEX=<file> +BIAS_HEX=<file>")
			end
			n = p_sequencer.ram_memory.load_hex(wgt_hex, 0, CNN_WGT_WORDS);
			if (n != CNN_WGT_WORDS) begin
				`uvm_warning(get_type_name(), $sformatf("weight file has %0d words (expected %0d)", n, CNN_WGT_WORDS))
			end
			n = p_sequencer.ram_memory.load_hex(bias_hex, CNN_BIAS_BASE, CNN_BIAS_COUNT);
			if (n != CNN_BIAS_COUNT) begin
				`uvm_warning(get_type_name(), $sformatf("bias file has %0d words (expected %0d)", n, CNN_BIAS_COUNT))
			end
		end
		cnn_infer_item::last_mode = DM_FILE;

		last_op = mk_op(OP_START, .irq_en_(irq_en));
		run_op(last_op);
		if (last_op.timeout || !last_op.done_seen) begin
			`uvm_error(get_type_name(), "file inference did not finish")
		end
	endtask
endclass

// ------------------------------------------------------------
// irq behavior
// ------------------------------------------------------------
class cnn_irq_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_irq_vseq)

	function new(string name = "cnn_irq_vseq");
		super.new(name);
	endfunction

	virtual task body();
		cnn_infer_item it;
		cnn_host_item  op;

		// 1) inference with irq_en = 0 -> done asserts but irq stays 0
		it = cnn_infer_item::type_id::create("irq_item0");
		it.fill(DM_SMALL);
		load_item(it);
		op = mk_op(OP_START, .irq_en_(1'b0), .wait_done_(1'b1), .auto_clear_(1'b0));
		run_op(op);
		if (op.timeout || !op.done_seen) `uvm_error(get_type_name(), "inference #1 did not finish")
		else if (op.irq_seen)            `uvm_error(get_type_name(), "irq asserted while irq_en=0")
		else                             `uvm_info(get_type_name(), "irq_en=0 : done without irq (OK)", UVM_LOW)

		// 2) irq_en = 1 while done is held -> irq goes to 1
		op = mk_op(OP_SET_IRQ_EN, .irq_en_(1'b1));
		run_op(op);
		if (!op.done_seen)     `uvm_error(get_type_name(), "done_status dropped without irq_clear")
		else if (!op.irq_seen) `uvm_error(get_type_name(), "irq not asserted after irq_en=1 with done_status=1")
		else                   `uvm_info(get_type_name(), "irq_en=1 : irq follows done_status (OK)", UVM_LOW)

		// 3) irq_clear -> done / irq go low
		op = mk_op(OP_IRQ_CLEAR);
		run_op(op);
		op = mk_op(OP_SET_IRQ_EN, .irq_en_(1'b1));
		run_op(op);
		if (op.done_seen || op.irq_seen) `uvm_error(get_type_name(), "done_status / irq still high after irq_clear")
		else                             `uvm_info(get_type_name(), "irq_clear : done / irq cleared (OK)", UVM_LOW)

		// 4) second inference with irq_en = 1 -> irq together with done
		it = cnn_infer_item::type_id::create("irq_item1");
		it.fill(DM_SPARSE);
		load_item(it);
		op = mk_op(OP_START, .irq_en_(1'b1), .wait_done_(1'b1), .auto_clear_(1'b1));
		run_op(op);
		if (op.timeout || !op.done_seen) `uvm_error(get_type_name(), "inference #2 did not finish")
		else if (!op.irq_seen)           `uvm_error(get_type_name(), "irq not asserted at done with irq_en=1")
		else                             `uvm_info(get_type_name(), "second inference : irq with done (OK)", UVM_LOW)
	endtask
endclass

// ------------------------------------------------------------
// reset during inference
// ------------------------------------------------------------
class cnn_reset_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_reset_vseq)

	rand int unsigned reset_after;      // reset this many cycles after start
	rand int unsigned reset_cycles;

	constraint c_rst {
		reset_after  inside {[200:200000]};
		reset_cycles inside {[2:10]};
	}

	function new(string name = "cnn_reset_vseq");
		super.new(name);
		reset_after  = 5000;
		reset_cycles = 5;
	endfunction

	virtual task body();
		cnn_infer_item it;
		cnn_host_item  op;
		cnn_infer_vseq s;

		// only start the inference
		it = cnn_infer_item::type_id::create("rst_item");
		it.fill(DM_SMALL);
		load_item(it);
		op = mk_op(OP_START, .irq_en_(1'b1), .wait_done_(1'b0), .auto_clear_(1'b0));
		run_op(op);

		// reset midway
		op = mk_op(OP_IDLE, .pre_delay_(reset_after));
		run_op(op);
		`uvm_info(get_type_name(), $sformatf("reset %0d cycles after start", reset_after), UVM_LOW)
		op = mk_op(OP_RESET, .reset_cycles_(reset_cycles));
		run_op(op);

		// normal inference after reset (new stimulus)
		s = cnn_infer_vseq::type_id::create("after_reset");
		s.data_mode = DM_SMALL;
		s.irq_en    = 1'b1;
		s.start(p_sequencer, this);
	endtask
endclass

// ------------------------------------------------------------
// functional coverage closure (fills every bin of cnn_coverage on its own)
//   1) random patterns (FULL / SMALL / SPARSE / ZERO) x every cp_result bin, fc2 bias steered : cx_mode_result
//      irq_en alternates 0 / 1 : cp_irq_en, SVA c_done_noirq
//   2) fixed patterns (MAX / MIN / ALT) : INT32 saturation, layers with no ReLU clamp, cp_mode
//      start_delay cycles 0 / 15 / 50 : cg_ctrl_start (START gap after irq_clear)
//   2) fixed patterns (MAX / MIN / ALT) : INT32 saturation, layers with no ReLU clamp, dead layers (MIN), cp_mode
//   3) the last stimulus saved to hex and run again through the file loader : cp_mode DM_FILE
//   4) irq protocol : irq_en 0 -> 1 -> 0 while done held, clear with done / without done / while busy : cg_ctrl_*
//   5) reset while busy in layer 0..3, while done held, while idle : cg_reset
// ------------------------------------------------------------
class cnn_cov_vseq extends cnn_vseq_base;
	`uvm_object_utils(cnn_cov_vseq)

	string img_hex = "cov_img.hex";
	string ram_hex = "cov_ram.hex";

	virtual cnn_ctrl_if ctrl_vif;     // only to wait for a layer before resetting

	function new(string name = "cnn_cov_vseq");
		super.new(name);
	endfunction

	// wait until the DUT is processing tiles of layer l (cnn_state W_LOAD .. NXT_TILE)
	task wait_layer(int l);
		longint cnt;
		cnt = 0;
		do begin
			@(ctrl_vif.mon_cb);
			cnt++;
			if (cnt > p_sequencer.cfg.done_timeout_cycles) begin
				`uvm_error(get_type_name(), $sformatf("layer %0d never reached", l))
				return;
			end
		end while (!((ctrl_vif.mon_cb.layer_idx == l) &&
		             (ctrl_vif.mon_cb.cnn_state inside {[CS_W_LOAD:CS_NXT_TILE]})));
	endtask

	// 4) irq protocol
	task irq_scenarios();
		cnn_infer_item it;
		cnn_host_item  op;

		// done held with irq_en = 0, then irq_en 0 -> 1 -> 0, clear (done held), clear again (nothing held)
		it = cnn_infer_item::type_id::create("cov_irq0");
		it.fill(DM_SMALL);
		load_item(it);
		`uvm_info(get_type_name(), "---- cov irq : irq_en change while done held / clear with and without done ----", UVM_LOW)
		run_op(mk_op(OP_START, .irq_en_(1'b0), .wait_done_(1'b1), .auto_clear_(1'b0)));
		op = mk_op(OP_SET_IRQ_EN, .irq_en_(1'b1));
		run_op(op);
		if (!op.irq_seen) `uvm_error(get_type_name(), "irq not asserted after irq_en 0 -> 1 with done_status held")
		op = mk_op(OP_SET_IRQ_EN, .irq_en_(1'b0));
		run_op(op);
		if (op.irq_seen)  `uvm_error(get_type_name(), "irq still high after irq_en 1 -> 0")
		run_op(mk_op(OP_IRQ_CLEAR));
		run_op(mk_op(OP_IRQ_CLEAR, .pre_delay_(5)));

		// irq_clear in the middle of an inference : must not disturb it (scoreboard checks the result)
		it = cnn_infer_item::type_id::create("cov_irq1");
		it.fill(DM_SPARSE);
		load_item(it);
		`uvm_info(get_type_name(), "---- cov irq : irq_clear while busy ----", UVM_LOW)
		run_op(mk_op(OP_START, .irq_en_(1'b1), .wait_done_(1'b0), .auto_clear_(1'b0)));
		run_op(mk_op(OP_IRQ_CLEAR, .pre_delay_(1000)));
		op = mk_op(OP_WAIT_DONE, .auto_clear_(1'b1));
		run_op(op);
		if (op.timeout || !op.done_seen) `uvm_error(get_type_name(), "inference with irq_clear while busy did not finish")
	endtask

	// 5) reset at every phase of an inference
	task reset_scenarios();
		cnn_infer_item it;

		for (int l = 0; l < 4; l++) begin
			it = cnn_infer_item::type_id::create($sformatf("cov_rst%0d", l));
			it.fill(DM_SMALL);
			load_item(it);
			`uvm_info(get_type_name(), $sformatf("---- cov reset : busy in layer %0d ----", l), UVM_LOW)
			run_op(mk_op(OP_START, .irq_en_(1'b1), .wait_done_(1'b0), .auto_clear_(1'b0)));
			wait_layer(l);
			run_op(mk_op(OP_RESET, .pre_delay_(2)));
		end

		// result held (not cleared) when reset comes
		it = cnn_infer_item::type_id::create("cov_rst_done");
		it.fill(DM_SMALL);
		load_item(it);
		`uvm_info(get_type_name(), "---- cov reset : done held ----", UVM_LOW)
		run_op(mk_op(OP_START, .irq_en_(1'b1), .wait_done_(1'b1), .auto_clear_(1'b0)));
		run_op(mk_op(OP_RESET, .pre_delay_(5)));

		// nothing running
		`uvm_info(get_type_name(), "---- cov reset : idle ----", UVM_LOW)
		run_op(mk_op(OP_RESET, .pre_delay_(20)));
	endtask

	virtual task body();
		cnn_data_mode_e     rnd_modes[4] = '{DM_FULL, DM_SMALL, DM_SPARSE, DM_ZERO};
		cnn_data_mode_e     fix_modes[3] = '{DM_MAX, DM_MIN, DM_ALT};
		cnn_target_e        targets[5]   = '{TGT_NEG_SAT, TGT_NEG, TGT_ZERO, TGT_POS, TGT_POS_SAT};
		cnn_infer_vseq      s;
		cnn_file_infer_vseq f;
		int                 n;
		int unsigned        gaps[3]      = '{0, 15, 50};

		if (!uvm_config_db#(virtual cnn_ctrl_if)::get(p_sequencer, "", "ctrl_vif", ctrl_vif)) begin
			`uvm_fatal(get_type_name(), "No find Virtual Interface(ctrl_vif) in config_db")
		end

		// 1) random patterns x result bins
		n = 0;
		foreach (rnd_modes[i]) begin
			foreach (targets[j]) begin
				s = cnn_infer_vseq::type_id::create($sformatf("cov_%0d", n));
				s.data_mode  = rnd_modes[i];
				s.target     = targets[j];
				s.irq_en      = (n % 2 == 1);
				s.sparse_pct  = 10;
				s.start_delay = gaps[n % 3];
				`uvm_info(get_type_name(), $sformatf("---- cov %0d : mode=%s target=%s irq_en=%0b start_delay=%0d ----",
					n, s.data_mode.name(), s.target.name(), s.irq_en, s.start_delay), UVM_LOW)
				s.start(p_sequencer, this);
				n++;
			end
		end

		// 2) fixed patterns (their result is set by the data, so no steering)
		foreach (fix_modes[i]) begin
			s = cnn_infer_vseq::type_id::create($sformatf("cov_%0d", n));
			s.data_mode = fix_modes[i];
			s.irq_en    = 1'b1;
			`uvm_info(get_type_name(), $sformatf("---- cov %0d : mode=%s ----", n, s.data_mode.name()), UVM_LOW)
			s.start(p_sequencer, this);
			n++;
		end

		// 3) hex round trip : the RAM models still hold the last stimulus
		p_sequencer.image_memory.save_hex(img_hex);
		p_sequencer.ram_memory.save_hex(ram_hex);
		f = cnn_file_infer_vseq::type_id::create("cov_file");
		f.img_hex = img_hex;
		f.ram_hex = ram_hex;
		`uvm_info(get_type_name(), $sformatf("---- cov %0d : mode=DM_FILE (%s, %s) ----", n, img_hex, ram_hex), UVM_LOW)
		f.start(p_sequencer, this);

		// 4) / 5) control protocol and reset (after the hex round trip : they overwrite the RAM models)
		irq_scenarios();
		reset_scenarios();
	endtask
endclass
