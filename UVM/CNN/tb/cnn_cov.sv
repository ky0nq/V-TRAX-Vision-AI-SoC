// ============================================================
// cnn_coverage : Functional coverage
//   cg_infer : final result range x data pattern, irq_en,
//              per-layer INT8 saturation (+ / - separately), INT32 saturation, ReLU clamp,
//              dead layer (whole layer output 0)
//   cg_layer : layer completion
//   cg_state : cnn_cntl FSM state / transition, tile states x layer (Conv path L0/L1, FC path L2/L3)
//   cg_ctrl  : host protocol (sampled from cnn_ctrl_if every clk / on host events)
//              irq_clear timing, irq_en changed while done_status is held, START gap after irq_clear
//   cg_reset : when reset hit (idle / done held / busy in layer 0..3)
//   inputs   : host_agent.monitor events (host_imp), predictor golden (exp_imp), cnn_ctrl_if (ctrl_vif)
// ============================================================
`uvm_analysis_imp_decl(_cov_host)
`uvm_analysis_imp_decl(_cov_exp)

class cnn_coverage extends uvm_component;
    `uvm_component_utils(cnn_coverage)

    uvm_analysis_imp_cov_host #(cnn_host_event, cnn_coverage) host_imp;
    uvm_analysis_imp_cov_exp  #(cnn_golden,     cnn_coverage) exp_imp;

    virtual cnn_ctrl_if ctrl_vif;

    // ---- Sampling variables ----
    byte signed     cov_result;
    cnn_data_mode_e cov_mode;
    bit             cov_irq_en;
    bit [3:0]       cov_sat8p;     // Per-layer INT8 positive saturation occurrence
    bit [3:0]       cov_sat8n;     // Per-layer INT8 negative saturation occurrence (only L3 : L0..L2 clamp negatives with ReLU)
    bit [3:0]       cov_sat32;     // Per-layer INT32 saturation occurrence
    bit [3:0]       cov_relu;      // Per-layer occurrence of values clamped to zero by ReLU
    bit [3:0]       cov_dead;      // Per-layer : every output of the layer is 0
    longint         cov_latency;
    int             cov_layer;
    int             cov_state;
    int             cov_state_layer;   // layer_idx while cnn_state is sampled

    // cg_ctrl
    int             cov_clear_when;    // CLR_* : state when irq_clear was seen
    int             cov_irq_en_chg;    // IEN_* : irq_en change while done_status held
    longint         cov_start_gap;     // clks from the last irq_clear to START

    // cg_reset
    int             cov_rst_when;      // RST_* : what the DUT was doing when rst_n fell

    localparam int CLR_DONE   = 0;     // done_status held, idle (normal clear)
    localparam int CLR_IDLE   = 1;     // idle, no done_status (redundant clear)
    localparam int CLR_BUSY   = 2;     // during an inference (must not disturb it)

    localparam int IEN_RISE   = 0;     // irq_en 0 -> 1 while done held : irq must rise
    localparam int IEN_FALL   = 1;     // irq_en 1 -> 0 while done held : irq must drop

    localparam int RST_IDLE   = 0;
    localparam int RST_DONE   = 1;     // done_status held (result not yet cleared)
    localparam int RST_BUSY_L = 2;     // + layer_idx : busy in layer 0..3

    cnn_golden      pending_q[$];
    longint         last_clear_cycle;  // host monitor cycle of the last irq_clear (-1 : none since reset)

    covergroup cg_infer;
        option.per_instance = 1;

        cp_result : coverpoint cov_result {
            bins neg_sat = {-128};
            bins neg     = {[-127:-1]};
            bins zero    = {0};
            bins pos     = {[1:126]};
            bins pos_sat = {127};
        }

        cp_mode   : coverpoint cov_mode;
        cp_irq_en : coverpoint cov_irq_en;

        cp_sat8p_l0 : coverpoint cov_sat8p[0];
        cp_sat8p_l1 : coverpoint cov_sat8p[1];
        cp_sat8p_l2 : coverpoint cov_sat8p[2];
        cp_sat8p_l3 : coverpoint cov_sat8p[3];
        cp_sat8n_l3 : coverpoint cov_sat8n[3];

        cp_sat32_l0 : coverpoint cov_sat32[0];
        cp_sat32_l1 : coverpoint cov_sat32[1];
        cp_sat32_l2 : coverpoint cov_sat32[2];
        cp_sat32_l3 : coverpoint cov_sat32[3];

        cp_relu_l0  : coverpoint cov_relu[0];
        cp_relu_l1  : coverpoint cov_relu[1];
        cp_relu_l2  : coverpoint cov_relu[2];

        // a whole layer of zeros (e.g. DM_MIN : every value clamped by ReLU) must still flow to the next layer
        cp_dead_l0  : coverpoint cov_dead[0];
        cp_dead_l1  : coverpoint cov_dead[1];
        cp_dead_l2  : coverpoint cov_dead[2];

        // Latency is constant regardless of input data
        // because RAM latency and tile processing order are fixed.
        // Therefore, latency is not divided into coverage bins.
        // cnn_scoreboard reports the min / avg / max latency values.

        // Result x pattern is crossed only for the random patterns (FULL / SMALL / SPARSE / ZERO).
        // DM_MAX / DM_MIN / DM_ALT use constant data, so each always gives the same single result
        // and its other 4 result bins can never be hit; DM_FILE gives whatever the file holds.
        // Those modes are still counted in cp_mode and cp_result.
        // cnn_cov_test steers the fc2 bias so every random pattern hits every result bin.
        cx_mode_result : cross cp_mode, cp_result {
            ignore_bins fixed_data = binsof(cp_mode) intersect {DM_MAX, DM_MIN, DM_ALT, DM_FILE};
        }
    endgroup

    covergroup cg_layer;
        option.per_instance = 1;

        cp_layer : coverpoint cov_layer {
            bins l[] = {[0:3]};
        }
    endgroup

    covergroup cg_state;
        option.per_instance = 1;

        cp_state : coverpoint cov_state {
            bins st[] = {[0:10]};
        }

        cp_trans : coverpoint cov_state {
            bins boot       = (0 => 1 => 2 => 3);
            bins first_tile = (3 => 4 => 5 => 6 => 7);
            bins next_tile  = (7 => 8 => 4);
            bins layer_end  = (8 => 9 => 3);
            bins finish     = (9 => 10 => 0);
        }

        // tile states only : layer_idx belongs to the layer being processed there
        cp_tile_state : coverpoint cov_state {
            bins st[] = {[CS_W_LOAD:CS_NXT_TILE]};
        }
        cp_state_layer : coverpoint cov_state_layer {
            bins l[] = {[0:3]};
        }
        // every tile state in every layer : Conv (L0 with pool, L1) and FC (L2, L3) paths
        cx_state_layer : cross cp_tile_state, cp_state_layer;
    endgroup

    covergroup cg_ctrl_clear;
        option.per_instance = 1;

        cp_clear_when : coverpoint cov_clear_when {
            bins done = {CLR_DONE};
            bins idle = {CLR_IDLE};
            bins busy = {CLR_BUSY};
        }
    endgroup

    covergroup cg_ctrl_irq_en;
        option.per_instance = 1;

        cp_irq_en_chg : coverpoint cov_irq_en_chg {
            bins rise = {IEN_RISE};
            bins fall = {IEN_FALL};
        }
    endgroup

    covergroup cg_ctrl_start;
        option.per_instance = 1;

        // START right after the previous result was cleared vs. after a pause
        cp_start_gap : coverpoint cov_start_gap {
            bins gap_b2b   = {[0:5]};
            bins gap_short = {[6:30]};
            bins gap_long  = {[31:$]};
        }
    endgroup

    covergroup cg_reset;
        option.per_instance = 1;

        cp_rst_when : coverpoint cov_rst_when {
            bins idle    = {RST_IDLE};
            bins done    = {RST_DONE};
            bins busy_l0 = {RST_BUSY_L + 0};
            bins busy_l1 = {RST_BUSY_L + 1};
            bins busy_l2 = {RST_BUSY_L + 2};
            bins busy_l3 = {RST_BUSY_L + 3};
        }
    endgroup

    function new(string name = "cnn_coverage", uvm_component parent);
        super.new(name, parent);

        host_imp = new("host_imp", this);
        exp_imp = new("exp_imp", this);

        cg_infer       = new();
        cg_layer       = new();
        cg_state       = new();
        cg_ctrl_clear  = new();
        cg_ctrl_irq_en = new();
        cg_ctrl_start  = new();
        cg_reset       = new();

        cov_result = 0;
        cov_mode = DM_SMALL;
        cov_irq_en = 0;
        cov_sat8p = 0;
        cov_sat8n = 0;
        cov_sat32 = 0;
        cov_relu = 0;
        cov_dead = 0;
        cov_latency = 0;
        cov_layer = 0;
        cov_state = 0;
        cov_state_layer = 0;
        cov_clear_when = 0;
        cov_irq_en_chg = 0;
        cov_start_gap = 0;
        cov_rst_when = 0;
        last_clear_cycle = -1;
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual cnn_ctrl_if)::get(
                this, "", "ctrl_vif", ctrl_vif)) begin
            `uvm_fatal(
                get_type_name(),
                "No find Virtual Interface(ctrl_vif) in config_db"
            )
        end
    endfunction

    function void write_cov_exp(cnn_golden g);
        pending_q.push_back(g);
    endfunction

    function void write_cov_host(cnn_host_event t);
        cnn_golden g;

        case (t.kind)

            EV_RESET: begin
                pending_q.delete();
                last_clear_cycle = -1;
            end

            EV_START: begin
                // first START after reset has no previous clear
                if (last_clear_cycle >= 0) begin
                    cov_start_gap = t.cycle - last_clear_cycle;
                    cg_ctrl_start.sample();
                end
            end

            EV_IRQ_CLEAR: begin
                last_clear_cycle = t.cycle;
            end

            EV_LAYER_DONE: begin
                cov_layer = t.layer_idx;
                cg_layer.sample();
            end

            EV_DONE: begin
                cov_result  = t.final_result;
                cov_irq_en  = t.irq_en;
                cov_latency = t.latency;

                if (pending_q.size() > 0) begin
                    g = pending_q.pop_front();
                    cov_mode = g.data_mode;

                    for (int l = 0; l < 4; l++) begin
                        cov_sat8p[l] = (g.sat8_pos_cnt[l] > 0);
                        cov_sat8n[l] = (g.sat8_neg_cnt[l] > 0);
                        cov_sat32[l] = (g.sat32_cnt[l] > 0);
                        cov_relu[l]  = (g.relu_cnt[l] > 0);
                        cov_dead[l]  = (g.nonzero_cnt[l] == 0);
                    end
                end

                cg_infer.sample();
            end

            default: begin
            end

        endcase
    endfunction

    // Every clk :
    //   FSM state whenever it changes (state transition bins)
    //   irq_clear / irq_en change with the DUT status of that clk
    //   on reset assert : what the DUT was doing in the clk before
    //     (rst_n is asynchronous, so the clk where rst_n is seen low already shows the reset state)
    virtual task run_phase(uvm_phase phase);
        int prev;
        bit prev_valid;
        int prev_st;
        int prev_layer;
        bit prev_done;
        bit prev_irq_en;

        prev       = -1;
        prev_valid = 1'b0;

        forever begin
            @(ctrl_vif.mon_cb);

            if (ctrl_vif.rst_n !== 1'b1) begin
                if (prev_valid) begin
                    if (prev_st != CS_IDLE) cov_rst_when = RST_BUSY_L + prev_layer;
                    else if (prev_done)     cov_rst_when = RST_DONE;
                    else                    cov_rst_when = RST_IDLE;
                    cg_reset.sample();
                end
                prev       = -1;
                prev_valid = 1'b0;
                continue;
            end

            if ($isunknown(ctrl_vif.mon_cb.cnn_state))
                continue;

            if (ctrl_vif.mon_cb.cnn_state != prev) begin
                cov_state       = ctrl_vif.mon_cb.cnn_state;
                cov_state_layer = ctrl_vif.mon_cb.layer_idx;
                cg_state.sample();
                prev = cov_state;
            end

            // irq_clear with the status of the same clk
            if (ctrl_vif.mon_cb.irq_clear === 1'b1) begin
                if (ctrl_vif.mon_cb.busy === 1'b1)             cov_clear_when = CLR_BUSY;
                else if (ctrl_vif.mon_cb.done_status === 1'b1) cov_clear_when = CLR_DONE;
                else                                           cov_clear_when = CLR_IDLE;
                cg_ctrl_clear.sample();
            end

            // irq_en changed while a result is held
            if (prev_valid && (ctrl_vif.mon_cb.irq_en !== prev_irq_en) &&
                (ctrl_vif.mon_cb.done_status === 1'b1) && (prev_done == 1'b1)) begin
                cov_irq_en_chg = (ctrl_vif.mon_cb.irq_en === 1'b1) ? IEN_RISE : IEN_FALL;
                cg_ctrl_irq_en.sample();
            end

            prev_valid  = 1'b1;
            prev_st     = ctrl_vif.mon_cb.cnn_state;
            prev_layer  = ctrl_vif.mon_cb.layer_idx;
            prev_done   = (ctrl_vif.mon_cb.done_status === 1'b1);
            prev_irq_en = (ctrl_vif.mon_cb.irq_en === 1'b1);
        end
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);

        `uvm_info(
            get_type_name(),
            $sformatf(
                {"coverage : cg_infer=%.1f%% cg_layer=%.1f%% cg_state=%.1f%%",
                 " cg_ctrl_clear=%.1f%% cg_ctrl_irq_en=%.1f%% cg_ctrl_start=%.1f%% cg_reset=%.1f%%"},
                cg_infer.get_inst_coverage(),
                cg_layer.get_inst_coverage(),
                cg_state.get_inst_coverage(),
                cg_ctrl_clear.get_inst_coverage(),
                cg_ctrl_irq_en.get_inst_coverage(),
                cg_ctrl_start.get_inst_coverage(),
                cg_reset.get_inst_coverage()
            ),
            UVM_LOW
        )
    endfunction

endclass
