// ============================================================
// cnn_infer_item : holds the stimulus of one inference (image + weight + bias) as logical tensors
//
//   img  [ (y*64 + x)*3 + c ]                 signed INT8, HWC
//   wL   [ oc*K + k ]                          k = (ky*3 + kx)*Cin + ci   (Conv)   /   k = input index (FC)
//   bias [ record ]                            record = Lx_PARAM_BASE + oc  (0 .. 42)
//
//   pack_to_mem()   : converts to the RAM layout the DUT reads (Image RAM word / shared RAM word) and writes to the mem model
//   unpack_from_mem : the reverse (the predictor builds the golden from the RAM contents at START time)
//
//   RAM layout (as seen by act_ld_unit / act_patch_gen / fc_gen / wgt_ld_unit / cnn_cntl)
//     Image RAM  word p = y*64 + x        : [7:0] ch0  [15:8] ch1  [23:16] ch2
//     Weight     word = Lx_W_BASE + og*K + k : lane c = k-th weight of oc (og*3 + c) (0 if oc >= Cout)
//     Bias       word = 45250 + record      : signed INT32
// ============================================================
class cnn_infer_item extends uvm_sequence_item;
	`uvm_object_utils(cnn_infer_item)

	rand cnn_data_mode_e data_mode;
	rand int unsigned    sparse_pct;      // DM_SPARSE : ratio of non-zero elements (%)

	// pattern of the stimulus last loaded into RAM (read by predictor / coverage at START time)
	static cnn_data_mode_e last_mode = DM_SMALL;

	byte signed img [];
	byte signed w0  [];
	byte signed w1  [];
	byte signed w2  [];
	byte signed w3  [];
	int  signed bias[];

	constraint c_mode {
		data_mode dist { DM_FULL := 4, DM_SMALL := 4, DM_SPARSE := 2, DM_ZERO := 1, DM_MAX := 1, DM_MIN := 1, DM_ALT := 1 };
	}
	constraint c_sparse { sparse_pct inside {[1:25]}; }

	function new(string name = "cnn_infer_item");
		super.new(name);
		img  = new[CNN_IMG_H * CNN_IMG_W * CNN_IMG_C];
		w0   = new[CNN_L0_OUT_C * CNN_L0_K];
		w1   = new[CNN_L1_OUT_C * CNN_L1_K];
		w2   = new[CNN_L2_OUT_C * CNN_L2_IN];
		w3   = new[CNN_L3_OUT_C * CNN_L3_IN];
		bias = new[CNN_BIAS_COUNT];
		data_mode  = DM_SMALL;
		sparse_pct = 10;
	endfunction

	function void post_randomize();
		fill(data_mode);
	endfunction

	// ------------------------------------------------------------
	// random helpers
	// ------------------------------------------------------------
	local function byte signed rnd8(int lo, int hi);
		int r;
		r = lo + $urandom_range(0, hi - lo);
		return byte'(r);
	endfunction

	local function int signed rnd32(int lo, int hi);
		longint r;
		r = longint'(lo) + longint'($urandom_range(0, hi - lo));
		return int'(r);
	endfunction

	// arguments after ref inherit its direction (IEEE 1800 13.3), so input must be written explicitly
	local function void fill_arr8(ref cnn_i8_arr_t a, input int lo, input int hi);
		foreach (a[i]) a[i] = rnd8(lo, hi);
	endfunction

	local function void fill_arr8_sparse(ref cnn_i8_arr_t a, input int lo, input int hi, input int unsigned pct);
		foreach (a[i]) a[i] = ($urandom_range(0, 99) < pct) ? rnd8(lo, hi) : 8'sd0;
	endfunction

	local function void fill_arr8_const(ref cnn_i8_arr_t a, input byte signed v);
		foreach (a[i]) a[i] = v;
	endfunction

	local function void fill_arr8_alt(ref cnn_i8_arr_t a);
		foreach (a[i]) a[i] = (i % 2 == 0) ? 8'sd127 : 8'sh80;   // 8'sh80 = -128
	endfunction

	// ------------------------------------------------------------
	// data patterns
	// ------------------------------------------------------------
	function void fill(cnn_data_mode_e mode);
		data_mode = mode;
		case (mode)
			DM_FULL: begin
				fill_arr8(img, -128, 127);
				fill_arr8(w0,  -128, 127);
				fill_arr8(w1,  -128, 127);
				fill_arr8(w2,  -128, 127);
				fill_arr8(w3,  -128, 127);
				foreach (bias[i]) bias[i] = rnd32(-(1 << 24), (1 << 24) - 1);
			end
			DM_SMALL: begin
				// ranges chosen so each layer output lands in the middle of the INT8 range (saturation occurs only rarely)
				fill_arr8(img, -128, 127);
				fill_arr8(w0,  -32, 31);
				fill_arr8(w1,  -32, 31);
				fill_arr8(w2,  -32, 31);
				fill_arr8(w3,  -64, 63);
				foreach (bias[i]) bias[i] = rnd32(-20000, 20000);
			end
			DM_SPARSE: begin
				fill_arr8_sparse(img, -128, 127, sparse_pct);
				fill_arr8_sparse(w0,  -128, 127, sparse_pct);
				fill_arr8_sparse(w1,  -128, 127, sparse_pct);
				fill_arr8_sparse(w2,  -128, 127, sparse_pct);
				fill_arr8_sparse(w3,  -128, 127, sparse_pct);
				foreach (bias[i]) bias[i] = ($urandom_range(0, 99) < sparse_pct) ? rnd32(-20000, 20000) : 0;
			end
			DM_ZERO: begin
				// image / weight 0 -> only bias passes through
				fill_arr8_const(img, 8'sd0);
				fill_arr8_const(w0,  8'sd0);
				fill_arr8_const(w1,  8'sd0);
				fill_arr8_const(w2,  8'sd0);
				fill_arr8_const(w3,  8'sd0);
				foreach (bias[i]) bias[i] = rnd32(-100000, 100000);
			end
			DM_MAX: begin
				// positive saturation : acc + bias overflows INT32 (post_process INT32 saturation path)
				fill_arr8_const(img, 8'sd127);
				fill_arr8_const(w0,  8'sd127);
				fill_arr8_const(w1,  8'sd127);
				fill_arr8_const(w2,  8'sd127);
				fill_arr8_const(w3,  8'sd127);
				foreach (bias[i]) bias[i] = 32'sh7FFF_FFFF;
			end
			DM_MIN: begin
				// products are (+) max, bias is INT32 min -> ReLU layers give 0, final FC2 saturates negative (-128)
				fill_arr8_const(img, 8'sh80);   // -128
				fill_arr8_const(w0,  8'sh80);
				fill_arr8_const(w1,  8'sh80);
				fill_arr8_const(w2,  8'sh80);
				fill_arr8_const(w3,  8'sh80);
				foreach (bias[i]) bias[i] = 32'sh8000_0000;
			end
			DM_ALT: begin
				fill_arr8_alt(img);
				fill_arr8_alt(w0);
				fill_arr8_alt(w1);
				fill_arr8_alt(w2);
				fill_arr8_alt(w3);
				foreach (bias[i]) bias[i] = (i % 2 == 0) ? 1000 : -1000;
			end
			DM_FILE: begin
				// load from file : tensors come from the mem model via unpack
			end
			default: begin
				`uvm_error(get_type_name(), $sformatf("unknown data_mode %0d", mode))
			end
		endcase
	endfunction

	// ------------------------------------------------------------
	// logical tensor -> RAM layout
	// ------------------------------------------------------------
	local function void pack_weights(cnn_mem_model ram, cnn_i8_arr_t w, int base, int cout, int k_total);
		int n_og;
		bit [31:0] word;
		n_og = (cout + 2) / 3;
		for (int og = 0; og < n_og; og++) begin
			for (int k = 0; k < k_total; k++) begin
				word = 32'd0;
				for (int c = 0; c < 3; c++) begin
					int oc;
					oc = og * 3 + c;
					if (oc < cout) word[8*c +: 8] = w[oc * k_total + k];
				end
				ram.write(base + og * k_total + k, word);
			end
		end
	endfunction

	function void pack_to_mem(cnn_mem_model img_mem, cnn_mem_model ram_mem);
		bit [31:0] word;
		for (int p = 0; p < CNN_IMG_WORDS; p++) begin
			word = {8'h00, img[p*3 + 2], img[p*3 + 1], img[p*3 + 0]};
			img_mem.write(p, word);
		end
		pack_weights(ram_mem, w0, CNN_L0_W_BASE, CNN_L0_OUT_C, CNN_L0_K);
		pack_weights(ram_mem, w1, CNN_L1_W_BASE, CNN_L1_OUT_C, CNN_L1_K);
		pack_weights(ram_mem, w2, CNN_L2_W_BASE, CNN_L2_OUT_C, CNN_L2_IN);
		pack_weights(ram_mem, w3, CNN_L3_W_BASE, CNN_L3_OUT_C, CNN_L3_IN);
		for (int i = 0; i < CNN_BIAS_COUNT; i++) ram_mem.write(CNN_BIAS_BASE + i, bias[i]);
		last_mode = data_mode;
	endfunction

	// ------------------------------------------------------------
	// RAM layout -> logical tensor (inverse of pack)
	// ------------------------------------------------------------
	local function void unpack_weights(cnn_mem_model ram, ref cnn_i8_arr_t w, input int base, input int cout, input int k_total);
		int n_og;
		bit [31:0] word;
		n_og = (cout + 2) / 3;
		for (int og = 0; og < n_og; og++) begin
			for (int k = 0; k < k_total; k++) begin
				word = ram.peek(base + og * k_total + k);
				for (int c = 0; c < 3; c++) begin
					int oc;
					oc = og * 3 + c;
					if (oc < cout) w[oc * k_total + k] = byte'(word[8*c +: 8]);
				end
			end
		end
	endfunction

	function void unpack_from_mem(cnn_mem_model img_mem, cnn_mem_model ram_mem);
		bit [31:0] word;
		for (int p = 0; p < CNN_IMG_WORDS; p++) begin
			word = img_mem.peek(p);
			img[p*3 + 0] = byte'(word[ 7: 0]);
			img[p*3 + 1] = byte'(word[15: 8]);
			img[p*3 + 2] = byte'(word[23:16]);
		end
		unpack_weights(ram_mem, w0, CNN_L0_W_BASE, CNN_L0_OUT_C, CNN_L0_K);
		unpack_weights(ram_mem, w1, CNN_L1_W_BASE, CNN_L1_OUT_C, CNN_L1_K);
		unpack_weights(ram_mem, w2, CNN_L2_W_BASE, CNN_L2_OUT_C, CNN_L2_IN);
		unpack_weights(ram_mem, w3, CNN_L3_W_BASE, CNN_L3_OUT_C, CNN_L3_IN);
		for (int i = 0; i < CNN_BIAS_COUNT; i++) bias[i] = int'(ram_mem.peek(CNN_BIAS_BASE + i));
	endfunction

	// ------------------------------------------------------------
	// uvm_object hooks
	// ------------------------------------------------------------
	function void do_copy(uvm_object rhs);
		cnn_infer_item rhs_;
		super.do_copy(rhs);
		if (!$cast(rhs_, rhs)) begin
			`uvm_fatal(get_type_name(), "do_copy : type mismatch")
		end
		data_mode  = rhs_.data_mode;
		sparse_pct = rhs_.sparse_pct;
		img  = rhs_.img;
		w0   = rhs_.w0;
		w1   = rhs_.w1;
		w2   = rhs_.w2;
		w3   = rhs_.w3;
		bias = rhs_.bias;
	endfunction

	function string convert2string();
		longint s_img, s_w, s_b;
		s_img = 0; s_w = 0; s_b = 0;
		foreach (img[i]) s_img += img[i];
		foreach (w0[i])  s_w   += w0[i];
		foreach (w1[i])  s_w   += w1[i];
		foreach (w2[i])  s_w   += w2[i];
		foreach (w3[i])  s_w   += w3[i];
		foreach (bias[i]) s_b  += bias[i];
		return $sformatf("mode=%s sparse=%0d%% img[0..3]=%0d,%0d,%0d,%0d sum(img)=%0d sum(w)=%0d sum(bias)=%0d bias[42]=%0d",
			data_mode.name(), sparse_pct, img[0], img[1], img[2], img[3], s_img, s_w, s_b, bias[CNN_L3_PB]);
	endfunction
endclass
