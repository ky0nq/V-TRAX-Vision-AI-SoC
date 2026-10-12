`timescale 1ns / 1ps

// ============================================================================
//  mm2s_controller  (= the DMA's Control Unit)
// ============================================================================
// Manages whether the DMA is "working or idle", and acts as the manager that gives the start signal to the datapath!! 
//
// [Operating modes]
//    Single mode (cyclic = 0) : start -> 1 frame -> IDLE
//    Cyclic mode (cyclic = 1) : start -> next frame immediately each time a frame ends -> ...
//                               keeps running without CPU intervention (VDMA circular mode)
//    3 conditions that stop the repetition
//        1) abort arrives (stop signal issued by the CPU)
//        2) cyclic bit is cleared (CPU orders a stop after the current frame)
//        3) an error occurs (something went wrong, so do not repeat any more)
// ============================================================================

module mm2s_controller #(
    parameter ADDR_WIDTH = 32  // Address width for error storage
)(
    input                           clk,
    input                           rst_n,

    // ------------------------------------------------------------------
    // Signals exchanged with the CPU
    // ------------------------------------------------------------------
    input                           start,        // Pulses for 1 clock when the BTT register is written -> start
    input                           abort,        // Pulses for 1 clock when 1 is written to CR[2] -> stop
    input                           cyclic,       // CR[4] : 1 = cyclic mode
    output reg                      busy,         // 1 = working -> SR[0]
    output reg                      done,         // 1 = done -> held until the next start
    output reg                      error,        // 1 = error occurred -> SR[4]
    output reg  [ADDR_WIDTH-1:0]    error_addr,   // Address where the error occurred -> READ_ERR register
    output reg                      frame_done,   // 1 clock each time a frame ends -> completion IRQ, cur_buf update

    // ------------------------------------------------------------------
    // Signals reported by the Datapath
    // ------------------------------------------------------------------
    input                           xfer_done,    // Signals that this frame has been fully read
    input                           err_valid,    // Slave returned an error response (SLVERR/DECERR)
    input                           cfg_err,      // Invalid configuration (alignment, address range, burst type, etc.)
    input       [ADDR_WIDTH-1:0]    err_addr,     // Error address computed by the datapath

    // ------------------------------------------------------------------
    // Commands to the Datapath
    // ------------------------------------------------------------------
    output                          en,           // 1 = OK to work now
    output reg                      init          // 1 clock: start of a new frame 
);

    // ------------------------------------------------------------------
    //   S_IDLE : idle. Waits only for start
    //   S_DATA : working. The datapath is reading data over AXI
    // ------------------------------------------------------------------
    localparam S_IDLE = 1'b0;
    localparam S_DATA = 1'b1;

    reg state;          // Current state

    // A note that "remembers" abort.
    // abort is a 1-clock pulse, so unless it is remembered until the frame ends (xfer_done),
    // we would forget "was I told to stop?" and repeat again. So once it arrives, it is held at 1.
    reg stop_req;

    // In S_DATA, en = 1 -> the datapath may issue AR requests
    assign en = (state == S_DATA);

    //   error     : error already recorded (from a previous clock)
    //   err_valid : response error that has just arrived
    //   cfg_err   : config error that has just been detected
    // If any of the three is set, do not repeat.
    // (the error register rises one clock late... err_valid / cfg_err are also checked so errors in the same clock are not missed)
    wire err_now = error || err_valid || cfg_err;

    always @(posedge clk) begin
        // ==============================================================
        // Reset
        // ==============================================================
        if (!rst_n) begin
            state      <= S_IDLE;
            init       <= 1'b0;
            frame_done <= 1'b0;
            stop_req   <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            error_addr <= {ADDR_WIDTH{1'b0}};
        end
        else begin
            init       <= 1'b0;
            frame_done <= 1'b0;

            case (state)
                // ======================================================
                // S_IDLE : idle
                // ======================================================
                S_IDLE: begin
                    if (start) begin                // CPU wrote BTT = go signal
                        state    <= S_DATA;         // Move to the working state
                        init     <= 1'b1;           // Signal the start of a new frame
                        stop_req <= 1'b0;           // Clear the previous abort memory
                        busy     <= 1'b1;           // Mark busy in SR
                        done     <= 1'b0;           // Clear the previous done flag
                        error    <= 1'b0;           // Clear the previous error record
                    end
                end

                // ======================================================
                // S_DATA : working
                // ======================================================
                S_DATA: begin
                    // --------------------------------------------------
                    // (1) Remember abort when it arrives
                    //     The datapath also receives abort directly and stops new AR requests,
                    //     then raises xfer_done after receiving all responses for requests already issued.
                    //     The controller only remembers it so it can decide "don't repeat" at that point.
                    // --------------------------------------------------
                    if (abort)
                        stop_req <= 1'b1;
                    // --------------------------------------------------
                    // (2) Error recording : store only the "first error"
                    //     !error condition: ignore from the second error on -> preserve the root cause
                    //     Note: for cfg_err cases the datapath gives address 0, so error_addr = 0
                    // --------------------------------------------------
                    if ((err_valid || cfg_err) && !error) begin
                        error      <= 1'b1;
                        error_addr <= err_addr;
                    end
                    // --------------------------------------------------
                    // (3) When a frame ends : decide whether to repeat or go idle
                    // --------------------------------------------------
                    if (xfer_done) begin
                        frame_done <= 1'b1; // Either way, first signal that one frame has ended
                        //   cyclic    : cyclic mode is on, and
                        //   !stop_req : no abort has arrived earlier, and
                        //   !abort    : no abort arrived in this very clock either, and
                        //               (stop_req only becomes 1 on the next clock, so this is checked too)
                        //   !err_now  : no error
                        if (cyclic && !stop_req && !abort && !err_now) begin
                            init <= 1'b1;           // Start the next frame immediately (state stays S_DATA)
                                                    // busy also stays 1 -> from the CPU's view it is continuously busy! 
                        end else begin
                            state <= S_IDLE;
                            busy  <= 1'b0;          // Lower busy
                            done  <= 1'b1;          // Set the "done" flag (held until the next start)
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule