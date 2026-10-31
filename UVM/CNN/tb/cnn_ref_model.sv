// ============================================================
// cnn_golden    : reference model result (per-layer intermediate activations + final angle + statistics)
// cnn_ref_model : computes the 4 layers with the same integer arithmetic as post_process
//
//   Layer arithmetic (same as post_process.v)
//     acc32 = wrap32( sum(a * w) )                      PE accumulator 32bit
//     sum   = sat_int32( acc32 + bias )
//     p     = sum * M                                    64bit
//     off   = (S == 0) ? 0 : (p < 0 ? 2^(S-1) - 1 : 2^(S-1))
//     r     = (p + off) >>> S                            round-to-nearest, ties away from zero
//     q     = ReLU ? (r < 0 ? 0 : sat8(r)) : sat8(r)
//   Layer 0 stores q after 2x2 MaxPool.  For the final FC2, sat8(r) without ReLU is o_final_result.
// ============================================================
class cnn_golden extends uvm_object;
	`uvm_object_utils(cnn_golden)

	cnn_data_mode_e data_mode;
	longint         start_cycle;

	byte signed act0[];       // Layer 0 output : 32 x 32 x 6 (HWC)  -> input_buf REGION_B
	byte signed act1[];       // Layer 1 output : 32 x 32 x 4 (HWC)  -> input_buf REGION_A
	byte signed act2[];       // Layer 2 output : 32                 -> input_buf REGION_B
	byte signed final_q;      // Layer 3 output : o_final_result

	longint     final_acc;    // fc2 MAC sum (before wrap)
	longint     final_sum;    // after adding bias (after INT32 saturation)
	longint     final_rounded;// after shift, before INT8 saturation

	int sat8_pos_cnt[4];
	int sat8_neg_cnt[4];
	int sat32_cnt   [4];
	int relu_cnt    [4];
	int nonzero_cnt [4];

	function new(string name = "cnn_golden");
		super.new(name);
		act0 = new[CNN_L1_IN_H * CNN_L1_IN_W * CNN_L1_IN_C];
		act1 = new[CNN_L1_IN_H * CNN_L1_IN_W * CNN_L1_OUT_C];
		act2 = new[CNN_L2_OUT_C];
		final_q = 0;
		final_acc = 0; final_sum = 0; final_rounded = 0;
		for (int l = 0; l < 4; l++) begin
			sat8_pos_cnt[l] = 0; sat8_neg_cnt[l] = 0; sat32_cnt[l] = 0; relu_cnt[l] = 0; nonzero_cnt[l] = 0;
		end
	endfunction

	// layout of layer results in input_buf (result_buf : word = dst + pos*ceil(C/3) + ch/3, lane = ch%3)
	local function cnn_exp_word_arr_t build_words(cnn_i8_arr_t act, int n_pos, int ch, int dst_base);
		cnn_exp_word_arr_t w;
		int wpp;
		wpp = (ch + 2) / 3;
		w = new[n_pos * wpp];
		for (int pos = 0; pos < n_pos; pos++) begin
			for (int g = 0; g < wpp; g++) begin
				int idx;
				idx = pos * wpp + g;
				w[idx].addr = dst_base + idx;
				w[idx].data = 24'd0;
				w[idx].be   = 3'b000;
				for (int c = 0; c < 3; c++) begin
					int ch_i;
					ch_i = g * 3 + c;
					if (ch_i < ch) begin
						w[idx].data[8*c +: 8] = act[pos * ch + ch_i];
						w[idx].be[c]          = 1'b1;
					end
				end
			end
		end
		return w;
	endfunction

	function cnn_exp_word_arr_t exp_words(int layer);
		cnn_exp_word_arr_t none;
		case (layer)
			0: return build_words(act0, CNN_L1_IN_H * CNN_L1_IN_W, CNN_L1_IN_C,  CNN_REGION_B);
			1: return build_words(act1, CNN_L1_IN_H * CNN_L1_IN_W, CNN_L1_OUT_C, CNN_REGION_A);
			2: return build_words(act2, 1,                          CNN_L2_OUT_C, CNN_REGION_B);
			default: begin
				none = new[0];
				return none;
			end
		endcase
	endfunction

	function string convert2string();
		return $sformatf("mode=%s final_q=%0d (acc=%0d sum=%0d rounded=%0d) sat8+=%p sat8-=%p sat32=%p relu0=%p nz=%p",
			data_mode.name(), final_q, final_acc, final_sum, final_rounded,
			sat8_pos_cnt, sat8_neg_cnt, sat32_cnt, relu_cnt, nonzero_cnt);
	endfunction
endclass


class cnn_ref_model extends uvm_object;
	`uvm_object_utils(cnn_ref_model)

	int qm[4];
	int qs[4];

	// requant by-products (for recording the final layer)
	longint last_sum;
	longint last_rounded;

	function new(string name = "cnn_ref_model");
		super.new(name);
		qm[0] = CNN_L0_QM;  qs[0] = CNN_L0_QS;
		qm[1] = CNN_L1_QM;  qs[1] = CNN_L1_QS;
		qm[2] = CNN_L2_QM;  qs[2] = CNN_L2_QS;
		qm[3] = CNN_L3_QM;  qs[3] = CNN_L3_QS;
		last_sum = 0; last_rounded = 0;
	endfunction

	function void set_quant(int m[4], int s[4]);
		for (int l = 0; l < 4; l++) begin
			qm[l] = m[l];
			qs[l] = s[l];
		end
	endfunction

	// ------------------------------------------------------------
	// requant identical to post_process
	// ------------------------------------------------------------
	function byte signed requant(longint acc, int bias, int layer, bit relu, cnn_golden g);
		int         acc32;
		longint     sum, p, half, off, r;
		byte signed q;

		acc32 = int'(acc);                                  // PE accumulator 32bit wrap
		sum   = longint'(acc32) + longint'(bias);
		if (sum > 64'sd2147483647) begin
			sum = 64'sd2147483647;
			g.sat32_cnt[layer]++;
		end
		else if (sum < -64'sd2147483648) begin
			sum = -64'sd2147483648;
			g.sat32_cnt[layer]++;
		end

		p    = sum * longint'(qm[layer]);
		half = (qs[layer] == 0) ? 64'sd0 : (64'sd1 <<< (qs[layer] - 1));
		off  = (qs[layer] == 0) ? 64'sd0 : ((p < 0) ? (half - 64'sd1) : half);
		r    = (p + off) >>> qs[layer];

		last_sum     = sum;
		last_rounded = r;

		if (relu && (r < 0)) begin
			q = 0;
			g.relu_cnt[layer]++;
		end
		else if (r > 127) begin
			q = 127;
			g.sat8_pos_cnt[layer]++;
		end
		else if (r < -128) begin
			q = -128;
			g.sat8_neg_cnt[layer]++;
		end
		else begin
			q = byte'(r);
		end
		if (q != 0) g.nonzero_cnt[layer]++;
		return q;
	endfunction

	// ------------------------------------------------------------
	// Conv 3x3, stride 1, zero pad 1, input / output HWC
	//   w[oc*K + k], k = (ky*3 + kx)*Cin + ci   (act_patch_gen beat order)
	// ------------------------------------------------------------
	function cnn_i8_arr_t conv3x3(cnn_i8_arr_t in_, int H, int W, int Cin,
	                              cnn_i8_arr_t w, int Cout,
	                              cnn_i32_arr_t bias, int bias_base,
	                              int layer, bit relu, cnn_golden g);
		cnn_i8_arr_t out_;
		int K;
		K    = 9 * Cin;
		out_ = new[H * W * Cout];
		for (int y = 0; y < H; y++) begin
			for (int x = 0; x < W; x++) begin
				for (int oc = 0; oc < Cout; oc++) begin
					longint acc;
					acc = 0;
					for (int ky = 0; ky < 3; ky++) begin
						for (int kx = 0; kx < 3; kx++) begin
							int iy, ix;
							iy = y + ky - 1;
							ix = x + kx - 1;
							if ((iy < 0) || (iy >= H) || (ix < 0) || (ix >= W)) continue;
							for (int ci = 0; ci < Cin; ci++) begin
								acc += longint'(in_[(iy * W + ix) * Cin + ci]) * longint'(w[oc * K + (ky * 3 + kx) * Cin + ci]);
							end
						end
					end
					out_[(y * W + x) * Cout + oc] = requant(acc, bias[bias_base + oc], layer, relu, g);
				end
			end
		end
		return out_;
	endfunction

	// ------------------------------------------------------------
	// 2x2 MaxPool, stride 2 (pooling_unit)
	// ------------------------------------------------------------
	function cnn_i8_arr_t maxpool2x2(cnn_i8_arr_t in_, int H, int W, int C);
		cnn_i8_arr_t out_;
		int Ho, Wo;
		Ho   = H / 2;
		Wo   = W / 2;
		out_ = new[Ho * Wo * C];
		for (int oy = 0; oy < Ho; oy++) begin
			for (int ox = 0; ox < Wo; ox++) begin
				for (int c = 0; c < C; c++) begin
					byte signed m, v;
					m = in_[((2 * oy) * W + (2 * ox)) * C + c];
					v = in_[((2 * oy) * W + (2 * ox + 1)) * C + c];         if (v > m) m = v;
					v = in_[((2 * oy + 1) * W + (2 * ox)) * C + c];         if (v > m) m = v;
					v = in_[((2 * oy + 1) * W + (2 * ox + 1)) * C + c];     if (v > m) m = v;
					out_[(oy * Wo + ox) * C + c] = m;
				end
			end
		end
		return out_;
	endfunction

	// ------------------------------------------------------------
	// Fully connected : out[oc] = requant( sum_k in[k] * w[oc*N + k] + bias )
	// ------------------------------------------------------------
	function cnn_i8_arr_t fc(cnn_i8_arr_t in_, int N,
	                         cnn_i8_arr_t w, int Cout,
	                         cnn_i32_arr_t bias, int bias_base,
	                         int layer, bit relu, cnn_golden g, bit record_final);
		cnn_i8_arr_t out_;
		out_ = new[Cout];
		for (int oc = 0; oc < Cout; oc++) begin
			longint acc;
			acc = 0;
			for (int k = 0; k < N; k++) begin
				acc += longint'(in_[k]) * longint'(w[oc * N + k]);
			end
			out_[oc] = requant(acc, bias[bias_base + oc], layer, relu, g);
			if (record_final && (oc == 0)) begin
				g.final_acc     = acc;
				g.final_sum     = last_sum;
				g.final_rounded = last_rounded;
			end
		end
		return out_;
	endfunction

	// ------------------------------------------------------------
	// all 4 layers
	// ------------------------------------------------------------
	function cnn_golden run(cnn_infer_item it);
		cnn_golden   g;
		cnn_i8_arr_t c0;
		cnn_i8_arr_t f;

		g = cnn_golden::type_id::create("golden");
		g.data_mode = it.data_mode;

		// Layer 0 : Conv0 3x3 3->6 + ReLU + requant, then 2x2 MaxPool -> 32x32x6
		c0     = conv3x3(it.img, CNN_IMG_H, CNN_IMG_W, CNN_IMG_C, it.w0, CNN_L0_OUT_C, it.bias, CNN_L0_PB, 0, 1'b1, g);
		g.act0 = maxpool2x2(c0, CNN_L0_OUT_H, CNN_L0_OUT_W, CNN_L0_OUT_C);

		// Layer 1 : Conv1 3x3 6->4 + ReLU -> 32x32x4
		g.act1 = conv3x3(g.act0, CNN_L1_IN_H, CNN_L1_IN_W, CNN_L1_IN_C, it.w1, CNN_L1_OUT_C, it.bias, CNN_L1_PB, 1, 1'b1, g);

		// Layer 2 : fc1 4096 -> 32 + ReLU   (input index k = pixel*4 + ch = HWC index of act1)
		g.act2 = fc(g.act1, CNN_L2_IN, it.w2, CNN_L2_OUT_C, it.bias, CNN_L2_PB, 2, 1'b1, g, 1'b0);

		// Layer 3 : fc2 32 -> 1, no ReLU, angle M/S
		f         = fc(g.act2, CNN_L3_IN, it.w3, CNN_L3_OUT_C, it.bias, CNN_L3_PB, 3, 1'b0, g, 1'b1);
		g.final_q = f[0];
		return g;
	endfunction
endclass
