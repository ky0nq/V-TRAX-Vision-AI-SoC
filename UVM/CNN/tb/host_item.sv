// ============================================================
// cnn_host_item : one operation executed by host_agent's driver (seq_item)
//   the driver writes the results (final_result / done_seen / irq_seen / cycles / timeout) back into the same object
// ============================================================
class cnn_host_item extends uvm_sequence_item;
	`uvm_object_utils(cnn_host_item)

	// ---- stimulus ----
	rand cnn_host_op_e op;
	rand bit           irq_en;          // OP_START / OP_SET_IRQ_EN : i_irq_en value
	rand int unsigned  pre_delay;       // wait clks before the operation
	rand bit           wait_done;       // OP_START : wait until done_status
	rand bit           auto_clear;      // OP_START + wait_done : irq_clear pulse after done
	rand int unsigned  reset_cycles;    // OP_RESET : clks to hold rst_n = 0

	// ---- response (filled by the driver) ----
	bit signed [7:0] final_result;
	bit              done_seen;
	bit              irq_seen;         // o_irq at done time (or after SET_IRQ_EN)
	bit              timeout;
	longint          cycles;           // clks from start fire -> done

	constraint c_default {
		pre_delay    inside {[0:20]};
		reset_cycles inside {[2:10]};
		soft wait_done  == 1'b1;
		soft auto_clear == 1'b1;
		soft irq_en     == 1'b1;
	}

	function new(string name = "cnn_host_item");
		super.new(name);
		op = OP_IDLE;
		irq_en = 1'b1;
		pre_delay = 0;
		wait_done = 1'b1;
		auto_clear = 1'b1;
		reset_cycles = 5;
		final_result = 0;
		done_seen = 1'b0;
		irq_seen = 1'b0;
		timeout = 1'b0;
		cycles = 0;
	endfunction

	function string convert2string();
		return $sformatf("op=%s irq_en=%0b pre_delay=%0d wait_done=%0b auto_clear=%0b rst=%0d | result=%0d done=%0b irq=%0b timeout=%0b cycles=%0d",
			op.name(), irq_en, pre_delay, wait_done, auto_clear, reset_cycles,
			final_result, done_seen, irq_seen, timeout, cycles);
	endfunction
endclass
