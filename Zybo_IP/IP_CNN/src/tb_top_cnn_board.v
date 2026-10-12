`timescale 1ns / 1ps
// top_cnn_board verification : runs ROM (N_IMG images in img.mem) + top_cnn through GPIO-style ctrl / status.
//   For each image, select it with ctrl[11:4] and start, then compare the angle with expected_angles.mem (reference model values from make_mem.py).
//   img.mem / wgt.mem / prm.mem must be in the run directory. expected_angles.mem is compared if present; otherwise only the angles are printed.
//   The ROM holds N_IMG (default 5) images; the number actually run is set automatically as (lines in img.mem) / 4096 (max N_IMG).
module tb_top_cnn_board #(parameter integer N_IMG = 40) ();   // Simulation ROM size (board top default is 5)
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg  [31:0] ctrl = 0;
    wire [31:0] status;
    top_cnn_board #(.N_IMG(N_IMG)) DUT (.clk(clk), .rst_n(rst_n), .i_ctrl(ctrl), .o_status(status));

    wire        done  = status[0], busy = status[1], start_ready = status[2], irq = status[3];
    wire [7:0]  angle = status[15:8];
    reg  [7:0]  exp_angle [0:255];
    integer errors = 0, t0, i, fd, n_lines, n_run;
    reg [255:0] line;
    task err; input [8*64-1:0] m; begin $display("  [ERROR] t=%0t %0s", $time, m); errors = errors + 1; end endtask

    task run_image; input integer n;
        begin
            ctrl = {20'd0, n[7:0], 4'h0}; @(negedge clk);
            ctrl = {20'd0, n[7:0], 4'h1}; repeat (3) @(negedge clk);          // start rising edge (latches the index)
            ctrl = {20'd0, n[7:0], 4'h0};
            t0 = $time;
            while (!done) begin @(negedge clk); if (($time - t0) > 64'd30_000_000) begin err("TIMEOUT"); $display("  status=%h", status); $finish; end end
            repeat (6) @(negedge clk);
            if (^exp_angle[n] === 1'bx)
                $display("  image %0d : angle = %0d   (%0d clk, status=%h)", n, $signed(angle), ($time - t0)/10, status);
            else begin
                $display("  image %0d : angle = %0d  (expected %0d)   (%0d clk, status=%h)", n, $signed(angle), $signed(exp_angle[n]), ($time - t0)/10, status);
                if (angle !== exp_angle[n]) err("angle mismatch");
            end
            if (busy) err("busy after done");
            if (!irq) err("irq=0");
            ctrl = {20'd0, n[7:0], 4'h2}; @(negedge clk); ctrl = 32'h0; repeat (2) @(negedge clk);   // irq_clear
            if (done) err("done not cleared");
            if (!start_ready) err("start_ready=0 after irq_clear");
        end
    endtask

    initial begin
        for (i = 0; i < 256; i = i + 1) exp_angle[i] = 8'hxx;
        fd = $fopen("expected_angles.mem", "r");
        if (fd) begin $fclose(fd); $readmemh("expected_angles.mem", exp_angle); end        // Skip comparison if missing
        // Determine the image count from the number of lines in img.mem
        n_lines = 0; fd = $fopen("img.mem", "r");
        if (fd) begin while (!$feof(fd)) begin if ($fgets(line, fd)) n_lines = n_lines + 1; end $fclose(fd); end
        n_run = n_lines / 4096;
        if (n_run > N_IMG) n_run = N_IMG;
        $display("  img.mem : %0d lines -> %0d image(s) (ROM N_IMG=%0d)", n_lines, n_run, N_IMG);
        if (n_run == 0) begin err("img.mem missing or shorter than 4096 lines"); $finish; end
        #55 rst_n = 1;
        repeat (5) @(negedge clk);
        if (!start_ready) err("start_ready=0 after reset");
        for (i = 0; i < n_run; i = i + 1) run_image(i);
        // Check that holding start at 1 starts only once (image 0)
        ctrl = 32'h1; t0 = $time;
        while (!done) begin @(negedge clk); if (($time - t0) > 64'd30_000_000) begin err("TIMEOUT 2"); $finish; end end
        repeat (6) @(negedge clk);
        if (^exp_angle[0] !== 1'bx && angle !== exp_angle[0]) err("angle mismatch (start held)");
        ctrl = 32'h0; repeat (20) @(negedge clk);
        if (busy) err("restarted while start held high");
        $display("errors = %0d", errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
