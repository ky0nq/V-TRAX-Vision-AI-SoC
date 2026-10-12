`timescale 1ns / 1ps

module timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cnt_en,
    input  wire [31:0] psc,
    input  wire [31:0] arr,
    input  wire        cnt_valid,
    input  wire [31:0] i_cnt,
    output wire [31:0] o_cnt,
    output wire        o_done
);

    reg [31:0] psc_counter;
    reg        psc_tick;
    reg [31:0] counter;
    reg        done_tick;

    assign o_cnt  = counter;
    assign o_done = done_tick;

    // ---- prescaler: count psc clocks and generate a 1-clock tick ----
    always @(posedge clk) begin
        if (!rst_n) begin
            psc_counter <= 0;
            psc_tick    <= 1'b0;
        end else begin
            psc_tick <= 1'b0;
            if (cnt_en) begin
                if (psc_counter == psc) begin
                    psc_counter <= 0;
                    psc_tick    <= 1'b1;
                end else begin
                    psc_counter <= psc_counter + 1;
                    psc_tick    <= 1'b0;
                end
            end
        end
    end

    // ---- main counter: increments by 1 on each psc_tick, asserts done_tick when it reaches arr ----
    always @(posedge clk) begin
        if (!rst_n) begin
            counter   <= 0;
            done_tick <= 1'b0;
        end else begin
            done_tick <= 1'b0;
            if (cnt_valid) begin
                counter <= i_cnt;
            end else if (cnt_en) begin
                if (psc_tick) begin
                    if (counter == arr) begin
                        counter   <= 0;
                        done_tick <= 1'b1;
                    end else begin
                        counter   <= counter + 1;
                        done_tick <= 1'b0;
                    end
                end
            end
        end
    end

endmodule