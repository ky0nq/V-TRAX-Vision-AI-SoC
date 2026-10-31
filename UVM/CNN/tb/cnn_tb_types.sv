// ============================================================
// cnn_tb_types.sv
//   Included first inside cnn_pkg.
//   Holds TB-side constants matching the DUT's fixed structure (cnn_cntl parameter defaults).
//   If the RTL parameters change, these must be changed as well.
// ============================================================

	// ---------------- Input image ----------------
	localparam int CNN_IMG_W      = 64;
	localparam int CNN_IMG_H      = 64;
	localparam int CNN_IMG_C      = 3;
	localparam int CNN_IMG_WORDS  = CNN_IMG_W * CNN_IMG_H;      // 4096 (1 word per pixel : lane0..2 = ch0..2)

	// ---------------- Layer 0 : Conv0 3x3 3->6, pad 1, ReLU, MaxPool 2x2 ----------------
	localparam int CNN_L0_OUT_C   = 6;
	localparam int CNN_L0_K       = 27;                        // 3 x 3 x 3
	localparam int CNN_L0_OUT_W   = 64;                        // before Pool
	localparam int CNN_L0_OUT_H   = 64;
	localparam int CNN_L0_W_BASE  = 0;
	localparam int CNN_L0_PB      = 0;                         // bias record base

	// ---------------- Layer 1 : Conv1 3x3 6->4, pad 1, ReLU ----------------
	localparam int CNN_L1_IN_W    = 32;
	localparam int CNN_L1_IN_H    = 32;
	localparam int CNN_L1_IN_C    = 6;
	localparam int CNN_L1_OUT_C   = 4;
	localparam int CNN_L1_K       = 54;                        // 3 x 3 x 6
	localparam int CNN_L1_W_BASE  = 54;
	localparam int CNN_L1_PB      = 6;

	// ---------------- Layer 2 : fc1 4096 -> 32, ReLU ----------------
	localparam int CNN_L2_IN      = 4096;                      // 32 x 32 x 4
	localparam int CNN_L2_OUT_C   = 32;
	localparam int CNN_L2_W_BASE  = 162;
	localparam int CNN_L2_PB      = 10;

	// ---------------- Layer 3 : fc2 32 -> 1 (final, no ReLU) ----------------
	localparam int CNN_L3_IN      = 32;
	localparam int CNN_L3_OUT_C   = 1;
	localparam int CNN_L3_W_BASE  = 45218;
	localparam int CNN_L3_PB      = 42;

	// ---------------- Shared RAM (Weight + Bias) ----------------
	localparam int CNN_WGT_WORDS  = 45250;                     // word 0 .. 45249 : weight (24bit used)
	localparam int CNN_BIAS_BASE  = 45250;                     // word 45250 .. 45292 : bias (32bit)
	localparam int CNN_BIAS_COUNT = 43;                        // 6 + 4 + 32 + 1
	localparam int CNN_RAM_WORDS  = CNN_BIAS_BASE + CNN_BIAS_COUNT;   // 45293

	// ---------------- input_buf regions ----------------
	localparam int CNN_IBUF_WORDS = 16384;
	localparam int CNN_REGION_A   = 0;
	localparam int CNN_REGION_B   = 8192;

	// ---------------- Requant M / S defaults (same as top_cnn parameter defaults) ----------------
	localparam int CNN_L0_QM = 1463994;
	localparam int CNN_L0_QS = 30;
	localparam int CNN_L1_QM = 4487009;
	localparam int CNN_L1_QS = 30;
	localparam int CNN_L2_QM = 849386;
	localparam int CNN_L2_QS = 30;
	localparam int CNN_L3_QM = 1046256;
	localparam int CNN_L3_QS = 30;

	// ---------------- cnn_cntl FSM encoding (o_cnn_state debug output) ----------------
	localparam int CS_IDLE       = 0;
	localparam int CS_START      = 1;
	localparam int CS_PARAM_LOAD = 2;
	localparam int CS_SET        = 3;
	localparam int CS_W_LOAD     = 4;
	localparam int CS_TILE_CFG   = 5;
	localparam int CS_PE_TILE    = 6;
	localparam int CS_PE_WAIT    = 7;
	localparam int CS_NXT_TILE   = 8;
	localparam int CS_LAYER_END  = 9;
	localparam int CS_DONE       = 10;

	// ---------------- Stimulus data patterns ----------------
	typedef enum {
		DM_FULL,     // image / weight full-range random, bias wide range
		DM_SMALL,    // small random values (path where saturation rarely occurs)
		DM_SPARSE,   // mostly 0, only some random
		DM_ZERO,     // all 0 (bias path only)
		DM_MAX,      // image / weight all +127, bias max -> positive saturation
		DM_MIN,      // image / weight all -128, bias min -> products positive, negative saturation via bias
		DM_ALT,      // alternating +127 / -128 (sign / position check)
		DM_FILE      // load from hex files (cnn_file_test)
	} cnn_data_mode_e;

	// ---------------- Final result target (fc2 bias steered so o_final_result lands in one cp_result bin) ----------------
	typedef enum {
		TGT_NONE,        // no steering : bias[42] as the data pattern made it
		TGT_NEG_SAT,     // -128
		TGT_NEG,         // -127 .. -1
		TGT_ZERO,        // 0
		TGT_POS,         // 1 .. 126
		TGT_POS_SAT      // 127
	} cnn_target_e;

	// ---------------- host_agent stimulus (operations executed by the driver) ----------------
	typedef enum {
		OP_RESET,        // rst_n held 0 for reset_cycles
		OP_START,        // start handshake (+ wait_done, + auto_clear)
		OP_WAIT_DONE,    // only wait for done_status
		OP_IRQ_CLEAR,    // irq_clear 1clk pulse
		OP_SET_IRQ_EN,   // set i_irq_en value
		OP_IDLE          // wait for pre_delay
	} cnn_host_op_e;

	// ---------------- Events emitted by host_agent's monitor ----------------
	typedef enum {
		EV_RESET,        // rst_n went to 0
		EV_START,        // start_valid && start_ready
		EV_LAYER_DONE,   // cnn_state left C_LAYER_END (layer_idx results fully written to input_buf)
		EV_DONE,         // done_status rising
		EV_IRQ_CLEAR     // irq_clear observed
	} cnn_host_kind_e;

	// ---------------- Common array types ----------------
	typedef byte signed cnn_i8_arr_t[];
	typedef int  signed cnn_i32_arr_t[];

	// One input_buf expected-value word compared by layer_scb
	typedef struct {
		int         addr;    // input_buf word address
		bit [23:0]  data;
		bit [ 2:0]  be;      // compare only these lanes (other lanes still hold previous values)
	} cnn_exp_word_t;
	typedef cnn_exp_word_t cnn_exp_word_arr_t[];

	// ---------------- act_buf_probe : input_buf white-box probe ----------------
	// layer_scb reads input_buf (activation buffer) through this handle.
	// The implementation (hierarchical reference `CNN_ACT_BUF_MEM) is done by cnn_act_buf_probe inside tb_top
	//   (an interface containing hierarchical references cannot be used as a virtual interface : IEEE 1800-2017 25.9)
	virtual class cnn_act_buf_probe_base;
		pure virtual function logic [23:0] act_buf_read(int unsigned addr);
	endclass
