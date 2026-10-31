// ============================================================
// cnn_host_driver : host_agent's driver. Acts as the SoC host
//   - Drives reset once at the beginning of run_phase,
//     and can also issue reset anytime through OP_RESET
//   - Performs start handshake (i_start_valid && o_start_ready)
//   - Waits for done_status, clears IRQ, and controls irq_en
// ============================================================
class cnn_host_driver extends uvm_driver #(cnn_host_item);
    `uvm_component_utils(cnn_host_driver)

    virtual cnn_ctrl_if ctrl_vif;
    cnn_env_cfg         cfg;

    function new(string name = "cnn_host_driver", uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual cnn_ctrl_if)::get(this, "", "ctrl_vif", ctrl_vif)) begin
            `uvm_fatal(get_type_name(), "No find Virtual Interface(ctrl_vif) in config_db")
        end

        if (!uvm_config_db#(cnn_env_cfg)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal(get_type_name(), "No find cnn_env_cfg(cfg) in config_db")
        end
    endfunction

    // ------------------------------------------------------------
    // Reset:
    // Change rst_n 1 ns after the clock edge to avoid edge overlap.
    // ------------------------------------------------------------
    virtual task do_reset(int unsigned cycles);
        `uvm_info(
            get_type_name(),
            $sformatf("RESET assert for %0d cycles", cycles),
            UVM_MEDIUM
        )

        @(ctrl_vif.drv_cb);

        ctrl_vif.drv_cb.start_valid <= 1'b0;
        ctrl_vif.drv_cb.irq_en      <= 1'b0;
        ctrl_vif.drv_cb.irq_clear   <= 1'b0;

        #1;
        ctrl_vif.rst_n = 1'b0;

        repeat (cycles)
            @(ctrl_vif.drv_cb);

        #1;
        ctrl_vif.rst_n = 1'b1;

        repeat (2)
            @(ctrl_vif.drv_cb);

        `uvm_info(get_type_name(), "RESET released", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Start handshake.
    // Returns after the handshake fires on a clock edge.
    // ------------------------------------------------------------
    virtual task do_start(cnn_host_item item);
        int unsigned cnt;

        ctrl_vif.drv_cb.irq_en <= item.irq_en;

        // Wait for start_ready
        cnt = 0;

        while (ctrl_vif.drv_cb.start_ready !== 1'b1) begin
            @(ctrl_vif.drv_cb);
            cnt++;

            if (cnt > cfg.ready_timeout_cycles) begin
                `uvm_error(
                    get_type_name(),
                    $sformatf(
                        "start_ready timeout after %0d cycles (done_status=%0b busy=%0b)",
                        cnt,
                        ctrl_vif.drv_cb.done_status,
                        ctrl_vif.drv_cb.busy
                    )
                )

                item.timeout = 1'b1;
                return;
            end
        end

        ctrl_vif.drv_cb.start_valid <= 1'b1;

        do begin
            @(ctrl_vif.drv_cb);
        end while (ctrl_vif.drv_cb.start_ready !== 1'b1);
        // Handshake fires on this edge

        ctrl_vif.drv_cb.start_valid <= 1'b0;

        `uvm_info(get_type_name(), "START fired", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    // Wait for done_status assertion.
    // ------------------------------------------------------------
    virtual task do_wait_done(cnn_host_item item);
        longint cnt;

        cnt = 0;

        while (ctrl_vif.drv_cb.done_status !== 1'b1) begin
            @(ctrl_vif.drv_cb);
            cnt++;

            if (cnt > cfg.done_timeout_cycles) begin
                `uvm_error(
                    get_type_name(),
                    $sformatf(
                        "done_status timeout after %0d cycles (cnn_state=%0d layer=%0d)",
                        cnt,
                        ctrl_vif.drv_cb.cnn_state,
                        ctrl_vif.drv_cb.layer_idx
                    )
                )

                item.timeout   = 1'b1;
                item.done_seen = 1'b0;
                item.cycles    = cnt;

                return;
            end
        end

        item.done_seen    = 1'b1;
        item.cycles       = cnt;
        item.final_result = ctrl_vif.drv_cb.final_result;
        item.irq_seen     = ctrl_vif.drv_cb.irq;

        `uvm_info(
            get_type_name(),
            $sformatf(
                "DONE : final_result=%0d irq=%0b after %0d cycles",
                item.final_result,
                item.irq_seen,
                cnt
            ),
            UVM_MEDIUM
        )
    endtask

    // ------------------------------------------------------------
    // Generate a 1-clock irq_clear pulse,
    // then briefly wait until done_status is deasserted.
    // ------------------------------------------------------------
    virtual task do_irq_clear();
        int unsigned cnt;

        ctrl_vif.drv_cb.irq_clear <= 1'b1;
        @(ctrl_vif.drv_cb);

        ctrl_vif.drv_cb.irq_clear <= 1'b0;

        cnt = 0;

        while (ctrl_vif.drv_cb.done_status !== 1'b0) begin
            @(ctrl_vif.drv_cb);
            cnt++;

            if (cnt > 8) begin
                `uvm_error(
                    get_type_name(),
                    "done_status did not clear after irq_clear"
                )
                break;
            end
        end

        `uvm_info(get_type_name(), "IRQ_CLEAR done", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        cnn_host_item item;

        // Apply the initial reset from the driver instead of tb_top.
        // Input signals are driven only through the clocking block.
        ctrl_vif.rst_n = 1'b0;

        ctrl_vif.drv_cb.start_valid <= 1'b0;
        ctrl_vif.drv_cb.irq_en      <= 1'b0;
        ctrl_vif.drv_cb.irq_clear   <= 1'b0;

        repeat (5)
            @(ctrl_vif.drv_cb);

        #1;
        ctrl_vif.rst_n = 1'b1;

        repeat (2)
            @(ctrl_vif.drv_cb);

        forever begin
            seq_item_port.get_next_item(item);

            `uvm_info(
                get_type_name(),
                $sformatf("Execute : %s", item.convert2string()),
                UVM_HIGH
            )

            repeat (item.pre_delay)
                @(ctrl_vif.drv_cb);

            case (item.op)

                OP_RESET: begin
                    do_reset(item.reset_cycles);
                end

                OP_START: begin
                    do_start(item);

                    if (!item.timeout && item.wait_done) begin
                        do_wait_done(item);

                        if (!item.timeout && item.auto_clear)
                            do_irq_clear();
                    end
                end

                OP_WAIT_DONE: begin
                    do_wait_done(item);

                    if (!item.timeout && item.auto_clear)
                        do_irq_clear();
                end

                OP_IRQ_CLEAR: begin
                    do_irq_clear();
                end

                OP_SET_IRQ_EN: begin
                    ctrl_vif.drv_cb.irq_en <= item.irq_en;

                    @(ctrl_vif.drv_cb);
                    @(ctrl_vif.drv_cb);

                    item.irq_seen  = ctrl_vif.drv_cb.irq;
                    item.done_seen = ctrl_vif.drv_cb.done_status;
                end

                OP_IDLE: begin
                    @(ctrl_vif.drv_cb);
                end

                default: begin
                    `uvm_error(get_type_name(), "Unknown host op")
                end

            endcase

            seq_item_port.item_done();
        end
    endtask

endclass
